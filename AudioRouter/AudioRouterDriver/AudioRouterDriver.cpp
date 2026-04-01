// AudioRouterDriver.cpp
// AudioServerPlugin (HAL plug-in) implementation.
//
// Virtual stereo output device. The HAL calls this plugin via the
// AudioServerPlugInDriverInterface vtable (COM-derived).
//
// References:
//   - AudioServerPlugIn.h (CoreAudio/AudioServerPlugIn.h)
//   - Apple NullAudio / SimpleAudio sample code
// ---------------------------------------------------------------------------

#include "AudioRouterDriver.h"

#include <CoreAudio/AudioHardware.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <os/log.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// ---------------------------------------------------------------------------
// Logging — os_log is visible in Console.app even from coreaudiod plugins
// ---------------------------------------------------------------------------
static os_log_t gLog = OS_LOG_DEFAULT;
#define AR_LOG(fmt, ...) \
    os_log(gLog, "[AudioRouterDriver] " fmt, ##__VA_ARGS__)

// ---------------------------------------------------------------------------
// Driver state
// ---------------------------------------------------------------------------
struct DriverState {
    pthread_mutex_t mutex;
    AudioObjectID   plugInObjectID;
    _Atomic(bool)   ioRunning;
    Float64         sampleRate;
    UInt64          anchorHostTime;
    Float64         anchorSampleTime;
    UInt32          safetyOffset;
    AudioServerPlugInHostRef hostRef;  // retained reference to the HAL host
};

static DriverState gState;

// ---------------------------------------------------------------------------
// Forward declarations — signatures must match AudioServerPlugInDriverInterface
// exactly (including COM QueryInterface/AddRef/Release).
// ---------------------------------------------------------------------------

// Per-process routing helper (defined before InstallMessagePort which calls it)
static OSStatus RouteProcessToDevice(int32_t targetPID, uint32_t deviceID);

// COM IUnknown
static HRESULT Driver_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface);
static ULONG   Driver_AddRef(void* inDriver);
static ULONG   Driver_Release(void* inDriver);

// AudioServerPlugIn lifecycle
static OSStatus PlugIn_Initialize(AudioServerPlugInDriverRef inDriver,
                                  AudioServerPlugInHostRef   inHost);
static OSStatus PlugIn_CreateDevice(AudioServerPlugInDriverRef inDriver,
                                    CFDictionaryRef inDescription,
                                    const AudioServerPlugInClientInfo* inClientInfo,
                                    AudioObjectID* outDeviceObjectID);
static OSStatus PlugIn_DestroyDevice(AudioServerPlugInDriverRef inDriver,
                                     AudioObjectID inDeviceObjectID);
static OSStatus PlugIn_AddDeviceClient(AudioServerPlugInDriverRef inDriver,
                                       AudioObjectID inDeviceObjectID,
                                       const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus PlugIn_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver,
                                          AudioObjectID inDeviceObjectID,
                                          const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus PlugIn_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver,
                                                        AudioObjectID inDeviceObjectID,
                                                        UInt64 inChangeAction,
                                                        void* inChangeInfo);
static OSStatus PlugIn_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver,
                                                      AudioObjectID inDeviceObjectID,
                                                      UInt64 inChangeAction,
                                                      void* inChangeInfo);

// AudioObject property methods
static Boolean  Object_HasProperty(AudioServerPlugInDriverRef inDriver,
                                   AudioObjectID inObjectID,
                                   pid_t inClientPID,
                                   const AudioObjectPropertyAddress* inAddress);
static OSStatus Object_IsPropertySettable(AudioServerPlugInDriverRef inDriver,
                                          AudioObjectID inObjectID,
                                          pid_t inClientPID,
                                          const AudioObjectPropertyAddress* inAddress,
                                          Boolean* outIsSettable);
static OSStatus Object_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver,
                                           AudioObjectID inObjectID,
                                           pid_t inClientPID,
                                           const AudioObjectPropertyAddress* inAddress,
                                           UInt32 inQualifierDataSize,
                                           const void* inQualifierData,
                                           UInt32* outDataSize);
static OSStatus Object_GetPropertyData(AudioServerPlugInDriverRef inDriver,
                                       AudioObjectID inObjectID,
                                       pid_t inClientPID,
                                       const AudioObjectPropertyAddress* inAddress,
                                       UInt32 inQualifierDataSize,
                                       const void* inQualifierData,
                                       UInt32 inDataSize,
                                       UInt32* outDataSize,
                                       void* outData);
static OSStatus Object_SetPropertyData(AudioServerPlugInDriverRef inDriver,
                                       AudioObjectID inObjectID,
                                       pid_t inClientPID,
                                       const AudioObjectPropertyAddress* inAddress,
                                       UInt32 inQualifierDataSize,
                                       const void* inQualifierData,
                                       UInt32 inDataSize,
                                       const void* inData);

// AudioDevice I/O methods
static OSStatus Device_StartIO(AudioServerPlugInDriverRef inDriver,
                               AudioObjectID inDeviceObjectID,
                               UInt32 inClientID);
static OSStatus Device_StopIO(AudioServerPlugInDriverRef inDriver,
                              AudioObjectID inDeviceObjectID,
                              UInt32 inClientID);
static OSStatus Device_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver,
                                        AudioObjectID inDeviceObjectID,
                                        UInt32 inClientID,
                                        Float64* outSampleTime,
                                        UInt64*  outHostTime,
                                        UInt64*  outSeed);
static OSStatus Device_WillDoIOOperation(AudioServerPlugInDriverRef inDriver,
                                         AudioObjectID inDeviceObjectID,
                                         UInt32 inClientID,
                                         UInt32 inOperationID,
                                         Boolean* outWillDo,
                                         Boolean* outWillDoInPlace);
static OSStatus Device_BeginIOOperation(AudioServerPlugInDriverRef inDriver,
                                        AudioObjectID inDeviceObjectID,
                                        UInt32 inClientID,
                                        UInt32 inOperationID,
                                        UInt32 inIOBufferFrameSize,
                                        const AudioServerPlugInIOCycleInfo* inIOCycleInfo);
static OSStatus Device_DoIOOperation(AudioServerPlugInDriverRef inDriver,
                                     AudioObjectID inDeviceObjectID,
                                     AudioObjectID inStreamObjectID,
                                     UInt32 inClientID,
                                     UInt32 inOperationID,
                                     UInt32 inIOBufferFrameSize,
                                     const AudioServerPlugInIOCycleInfo* inIOCycleInfo,
                                     void* ioMainBuffer,
                                     void* ioSecondaryBuffer);
static OSStatus Device_EndIOOperation(AudioServerPlugInDriverRef inDriver,
                                      AudioObjectID inDeviceObjectID,
                                      UInt32 inClientID,
                                      UInt32 inOperationID,
                                      UInt32 inIOBufferFrameSize,
                                      const AudioServerPlugInIOCycleInfo* inIOCycleInfo);

// ---------------------------------------------------------------------------
// VTable — order and types must exactly match AudioServerPlugInDriverInterface
// ---------------------------------------------------------------------------
static AudioServerPlugInDriverInterface gDriverInterface = {
    NULL,                                        // _reserved
    Driver_QueryInterface,                       // QueryInterface  (COM)
    Driver_AddRef,                               // AddRef          (COM)
    Driver_Release,                              // Release         (COM)
    PlugIn_Initialize,
    PlugIn_CreateDevice,
    PlugIn_DestroyDevice,
    PlugIn_AddDeviceClient,
    PlugIn_RemoveDeviceClient,
    PlugIn_PerformDeviceConfigurationChange,
    PlugIn_AbortDeviceConfigurationChange,
    Object_HasProperty,
    Object_IsPropertySettable,
    Object_GetPropertyDataSize,
    Object_GetPropertyData,
    Object_SetPropertyData,
    Device_StartIO,
    Device_StopIO,
    Device_GetZeroTimeStamp,
    Device_WillDoIOOperation,
    Device_BeginIOOperation,
    Device_DoIOOperation,
    Device_EndIOOperation
};

static AudioServerPlugInDriverInterface* gDriverInterfacePtr = &gDriverInterface;
static AudioServerPlugInDriverRef        gDriverRef           = &gDriverInterfacePtr;

// ---------------------------------------------------------------------------
// Plugin entry point
// ---------------------------------------------------------------------------
extern "C"
void* AudioServerPlugInMain(CFAllocatorRef /*inAllocator*/,
                             CFUUIDRef      inRequestedTypeUUID)
{
    if (!CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID)) {
        AR_LOG("Unexpected type UUID");
        return NULL;
    }
    gLog = os_log_create("com.audiorouter.driver", "driver");
    pthread_mutex_init(&gState.mutex, NULL);
    gState.sampleRate   = kDevice_SampleRate;
    gState.safetyOffset = 256;
    gState.hostRef      = NULL;
    atomic_init(&gState.ioRunning, false);
    AR_LOG("AudioServerPlugInMain called — v2 (coreaudiod routing)");
    return gDriverRef;
}

// ---------------------------------------------------------------------------
// COM IUnknown
// ---------------------------------------------------------------------------
static HRESULT Driver_QueryInterface(void* /*inDriver*/, REFIID inUUID, LPVOID* outInterface)
{
    // REFIID is CFUUIDBytes; create a temporary CFUUIDRef to compare.
    CFUUIDRef uuid = CFUUIDCreateFromUUIDBytes(kCFAllocatorDefault, inUUID);
    bool match = CFEqual(uuid, kAudioServerPlugInDriverInterfaceUUID) ||
                 CFEqual(uuid, IUnknownUUID);
    CFRelease(uuid);
    if (match) {
        *outInterface = gDriverRef;
        return S_OK;
    }
    *outInterface = NULL;
    return E_NOINTERFACE;
}

static ULONG Driver_AddRef(void* /*inDriver*/)  { return 1; }
static ULONG Driver_Release(void* /*inDriver*/) { return 1; }

// ---------------------------------------------------------------------------
// PlugIn lifecycle
// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------
// CFMessagePort IPC — receives routing commands from the main app
// ---------------------------------------------------------------------------
static CFDataRef RouteMessageCallback(CFMessagePortRef /*port*/,
                                       SInt32 /*msgid*/,
                                       CFDataRef data,
                                       void* /*info*/)
{
    if (!data || CFDataGetLength(data) < (CFIndex)sizeof(ARRouteCommand)) {
        AR_LOG("RouteMessageCallback: invalid data length");
        return NULL;
    }
    const ARRouteCommand* cmd =
        reinterpret_cast<const ARRouteCommand*>(CFDataGetBytePtr(data));
    AR_LOG("RouteMessageCallback: pid=%d deviceID=%u", cmd->pid, cmd->deviceID);
    OSStatus status = RouteProcessToDevice(cmd->pid, cmd->deviceID);
    AR_LOG("RouteProcessToDevice result: %d", (int)status);
    return NULL;
}

// Dedicated thread that owns the CFRunLoop for the message port.
// macOS 15 runs each HAL plugin in an XPC sandbox process driven by dispatch
// queues, not CFRunLoop. Adding a RunLoopSource to CFRunLoopGetCurrent() at
// init time leaves it on a loop that never spins, so messages are never
// processed. A dedicated pthread with CFRunLoopRun() fixes this.
static void* MessagePortThreadFunc(void* /*arg*/)
{
    CFMessagePortRef port = CFMessagePortCreateLocal(
        kCFAllocatorDefault,
        CFSTR("com.audiorouter.route"),
        RouteMessageCallback,
        NULL,
        NULL
    );
    if (!port) {
        AR_LOG("MessagePortThread: CFMessagePortCreateLocal failed");
        return NULL;
    }
    CFRunLoopSourceRef src =
        CFMessagePortCreateRunLoopSource(kCFAllocatorDefault, port, 0);
    if (!src) {
        AR_LOG("MessagePortThread: CFMessagePortCreateRunLoopSource failed");
        CFRelease(port);
        return NULL;
    }
    CFRunLoopAddSource(CFRunLoopGetCurrent(), src, kCFRunLoopDefaultMode);
    CFRelease(src);
    AR_LOG("MessagePort installed on dedicated thread: com.audiorouter.route");
    CFRunLoopRun();  // blocks until port is invalidated
    CFRelease(port);
    return NULL;
}

static void InstallMessagePort()
{
    pthread_t thread;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    int err = pthread_create(&thread, &attr, MessagePortThreadFunc, NULL);
    pthread_attr_destroy(&attr);
    if (err != 0) {
        AR_LOG("InstallMessagePort: pthread_create failed: %d", err);
    }
}

static OSStatus PlugIn_Initialize(AudioServerPlugInDriverRef /*inDriver*/,
                                  AudioServerPlugInHostRef   inHost)
{
    AR_LOG("Initialize — v4 (CFMessagePort on dedicated thread)");
    gState.hostRef = inHost;
    InstallMessagePort();
    return noErr;
}

static OSStatus PlugIn_CreateDevice(AudioServerPlugInDriverRef /*inDriver*/,
                                    CFDictionaryRef /*inDescription*/,
                                    const AudioServerPlugInClientInfo* /*inClientInfo*/,
                                    AudioObjectID* outDeviceObjectID)
{
    if (outDeviceObjectID) *outDeviceObjectID = kObjectID_Device;
    return noErr;
}

static OSStatus PlugIn_DestroyDevice(AudioServerPlugInDriverRef /*inDriver*/,
                                     AudioObjectID /*inDeviceObjectID*/)
{ return noErr; }

static OSStatus PlugIn_AddDeviceClient(AudioServerPlugInDriverRef /*inDriver*/,
                                       AudioObjectID /*inDeviceObjectID*/,
                                       const AudioServerPlugInClientInfo* /*inClientInfo*/)
{ return noErr; }

static OSStatus PlugIn_RemoveDeviceClient(AudioServerPlugInDriverRef /*inDriver*/,
                                          AudioObjectID /*inDeviceObjectID*/,
                                          const AudioServerPlugInClientInfo* /*inClientInfo*/)
{ return noErr; }

static OSStatus PlugIn_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef /*inDriver*/,
                                                        AudioObjectID /*inDeviceObjectID*/,
                                                        UInt64 /*inChangeAction*/,
                                                        void* /*inChangeInfo*/)
{ return noErr; }

static OSStatus PlugIn_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef /*inDriver*/,
                                                      AudioObjectID /*inDeviceObjectID*/,
                                                      UInt64 /*inChangeAction*/,
                                                      void* /*inChangeInfo*/)
{ return noErr; }

// ---------------------------------------------------------------------------
// Per-process routing — called from within coreaudiod context
// ---------------------------------------------------------------------------
static OSStatus RouteProcessToDevice(int32_t targetPID, uint32_t deviceID)
{
    AR_LOG("RouteProcessToDevice: pid=%d deviceID=%u", targetPID, deviceID);

    AudioObjectPropertyAddress listAddr = {
        kAudioHardwarePropertyProcessObjectList,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    UInt32 size = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(
        kAudioObjectSystemObject, &listAddr, 0, NULL, &size);
    if (status != noErr || size == 0) {
        AR_LOG("ProcessObjectList size error: %d", (int)status);
        return status != noErr ? status : kAudioHardwareBadObjectError;
    }

    UInt32 count = size / sizeof(AudioObjectID);
    AudioObjectID* objs = (AudioObjectID*)malloc(size);
    if (!objs) return kAudio_MemFullError;

    status = AudioObjectGetPropertyData(
        kAudioObjectSystemObject, &listAddr, 0, NULL, &size, objs);
    if (status != noErr) {
        AR_LOG("ProcessObjectList get error: %d", (int)status);
        free(objs);
        return status;
    }

    AudioObjectPropertyAddress pidAddr = {
        kAudioProcessPropertyPID,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };

    for (UInt32 i = 0; i < count; i++) {
        pid_t pid = 0;
        UInt32 pidSize = sizeof(pid_t);
        if (AudioObjectGetPropertyData(objs[i], &pidAddr, 0, NULL, &pidSize, &pid) != noErr) continue;
        if (pid != (pid_t)targetPID) continue;

        AR_LOG("Found process object %u for pid=%d, assigning deviceID=%u", objs[i], targetPID, deviceID);

        AudioObjectPropertyAddress devAddr = {
            kAudioProcessPropertyDevices,
            kAudioObjectPropertyScopeOutput,
            kAudioObjectPropertyElementMain
        };
        UInt32 devSize = sizeof(AudioDeviceID);
        AudioDeviceID dev = (AudioDeviceID)deviceID;
        status = AudioObjectSetPropertyData(objs[i], &devAddr, 0, NULL, devSize, &dev);
        AR_LOG("kAudioProcessPropertyDevices SET: status=%d (0x%X)", (int)status, (unsigned)status);
        free(objs);
        return status;
    }

    AR_LOG("pid=%d not found in process list", targetPID);
    free(objs);
    return kAudioHardwareBadObjectError;
}

// ---------------------------------------------------------------------------
// Stream format helper
// ---------------------------------------------------------------------------
static void FillASBD(AudioStreamBasicDescription* asbd)
{
    asbd->mSampleRate       = kDevice_SampleRate;
    asbd->mFormatID         = kAudioFormatLinearPCM;
    asbd->mFormatFlags      = kAudioFormatFlagIsFloat |
                              kAudioFormatFlagsNativeEndian |
                              kAudioFormatFlagIsPacked;
    asbd->mBytesPerPacket   = kDevice_BytesPerPacket;
    asbd->mFramesPerPacket  = kDevice_FramesPerPacket;
    asbd->mBytesPerFrame    = kDevice_BytesPerFrame;
    asbd->mChannelsPerFrame = kDevice_ChannelsPerFrame;
    asbd->mBitsPerChannel   = kDevice_BitsPerChannel;
    asbd->mReserved         = 0;
}

// ---------------------------------------------------------------------------
// HasProperty
// ---------------------------------------------------------------------------
static Boolean Object_HasProperty(AudioServerPlugInDriverRef /*inDriver*/,
                                  AudioObjectID inObjectID,
                                  pid_t /*inClientPID*/,
                                  const AudioObjectPropertyAddress* inAddress)
{
    switch (inObjectID) {
    case kObjectID_PlugIn:
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioPlugInPropertyDeviceList:
        case kAudioPlugInPropertyTranslateUIDToDevice:
            return true;
        default: return false;
        }
    case kObjectID_Device:
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:
        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyRelatedDevices:
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertyStreams:
        case kAudioObjectPropertyControlList:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyNominalSampleRate:
        case kAudioDevicePropertyAvailableNominalSampleRates:
        case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertyZeroTimeStampPeriod:
            return true;
        case kARPropertyRouteProcess:
            AR_LOG("HasProperty: kARPropertyRouteProcess queried");
            return true;
        default: return false;
        }
    case kObjectID_Stream_Output:
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName:
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
        case kAudioStreamPropertyLatency:
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            return true;
        default: return false;
        }
    default:
        return false;
    }
}

// ---------------------------------------------------------------------------
// IsPropertySettable
// ---------------------------------------------------------------------------
static OSStatus Object_IsPropertySettable(AudioServerPlugInDriverRef /*inDriver*/,
                                          AudioObjectID inObjectID,
                                          pid_t /*inClientPID*/,
                                          const AudioObjectPropertyAddress* inAddress,
                                          Boolean* outIsSettable)
{
    *outIsSettable = false;
    if (inObjectID == kObjectID_Device) {
        if (inAddress->mSelector == kAudioDevicePropertyNominalSampleRate ||
            inAddress->mSelector == kARPropertyRouteProcess) {
            *outIsSettable = true;
        }
    }
    return noErr;
}

// ---------------------------------------------------------------------------
// GetPropertyDataSize
// ---------------------------------------------------------------------------
static OSStatus Object_GetPropertyDataSize(AudioServerPlugInDriverRef /*inDriver*/,
                                           AudioObjectID inObjectID,
                                           pid_t /*inClientPID*/,
                                           const AudioObjectPropertyAddress* inAddress,
                                           UInt32 /*inQualifierDataSize*/,
                                           const void* /*inQualifierData*/,
                                           UInt32* outDataSize)
{
    switch (inObjectID) {
    case kObjectID_PlugIn:
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
            *outDataSize = sizeof(AudioClassID); return noErr;
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
            *outDataSize = sizeof(CFStringRef); return noErr;
        case kAudioPlugInPropertyDeviceList:
            *outDataSize = sizeof(AudioObjectID); return noErr;
        case kAudioPlugInPropertyTranslateUIDToDevice:
            *outDataSize = sizeof(AudioObjectID); return noErr;
        default: return kAudioHardwareUnknownPropertyError;
        }

    case kObjectID_Device:
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyZeroTimeStampPeriod:
        case kAudioDevicePropertyIsHidden:
            *outDataSize = sizeof(UInt32); return noErr;
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:
            *outDataSize = sizeof(CFStringRef); return noErr;
        case kAudioDevicePropertyRelatedDevices:
            *outDataSize = sizeof(AudioObjectID); return noErr;
        case kAudioDevicePropertyStreams:
            *outDataSize = (inAddress->mScope == kAudioObjectPropertyScopeOutput)
                            ? sizeof(AudioObjectID) : 0;
            return noErr;
        case kAudioObjectPropertyControlList:
            *outDataSize = 2 * sizeof(AudioObjectID); return noErr;
        case kAudioDevicePropertyNominalSampleRate:
            *outDataSize = sizeof(Float64); return noErr;
        case kAudioDevicePropertyAvailableNominalSampleRates:
            *outDataSize = sizeof(AudioValueRange); return noErr;
        case kARPropertyRouteProcess:
            *outDataSize = sizeof(ARRouteCommand); return noErr;
        default: return kAudioHardwareUnknownPropertyError;
        }

    case kObjectID_Stream_Output:
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
        case kAudioStreamPropertyLatency:
            *outDataSize = sizeof(UInt32); return noErr;
        case kAudioObjectPropertyName:
            *outDataSize = sizeof(CFStringRef); return noErr;
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            *outDataSize = sizeof(AudioStreamBasicDescription); return noErr;
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            *outDataSize = sizeof(AudioStreamRangedDescription); return noErr;
        default: return kAudioHardwareUnknownPropertyError;
        }

    default:
        return kAudioHardwareBadObjectError;
    }
}

// ---------------------------------------------------------------------------
// GetPropertyData
// ---------------------------------------------------------------------------
static OSStatus Object_GetPropertyData(AudioServerPlugInDriverRef /*inDriver*/,
                                       AudioObjectID inObjectID,
                                       pid_t /*inClientPID*/,
                                       const AudioObjectPropertyAddress* inAddress,
                                       UInt32 /*inQualifierDataSize*/,
                                       const void* /*inQualifierData*/,
                                       UInt32 /*inDataSize*/,
                                       UInt32* outDataSize,
                                       void* outData)
{
    switch (inObjectID) {

    // ---- PlugIn ----
    case kObjectID_PlugIn:
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
            *outDataSize = sizeof(AudioClassID);
            *static_cast<AudioClassID*>(outData) = kAudioObjectClassID;
            return noErr;
        case kAudioObjectPropertyClass:
            *outDataSize = sizeof(AudioClassID);
            *static_cast<AudioClassID*>(outData) = kAudioPlugInClassID;
            return noErr;
        case kAudioObjectPropertyOwner:
            *outDataSize = sizeof(AudioObjectID);
            *static_cast<AudioObjectID*>(outData) = kAudioObjectSystemObject;
            return noErr;
        case kAudioObjectPropertyName:
            *outDataSize = sizeof(CFStringRef);
            *static_cast<CFStringRef*>(outData) = CFSTR("AudioRouter");
            return noErr;
        case kAudioObjectPropertyManufacturer:
            *outDataSize = sizeof(CFStringRef);
            *static_cast<CFStringRef*>(outData) = CFSTR("AudioRouter");
            return noErr;
        case kAudioPlugInPropertyDeviceList:
            *outDataSize = sizeof(AudioObjectID);
            *static_cast<AudioObjectID*>(outData) = kObjectID_Device;
            return noErr;
        case kAudioPlugInPropertyTranslateUIDToDevice:
            *outDataSize = sizeof(AudioObjectID);
            *static_cast<AudioObjectID*>(outData) = kObjectID_Device;
            return noErr;
        default: return kAudioHardwareUnknownPropertyError;
        }

    // ---- Device ----
    case kObjectID_Device:
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
            *outDataSize = sizeof(AudioClassID);
            *static_cast<AudioClassID*>(outData) = kAudioObjectClassID;
            return noErr;
        case kAudioObjectPropertyClass:
            *outDataSize = sizeof(AudioClassID);
            *static_cast<AudioClassID*>(outData) = kAudioDeviceClassID;
            return noErr;
        case kAudioObjectPropertyOwner:
            *outDataSize = sizeof(AudioObjectID);
            *static_cast<AudioObjectID*>(outData) = kObjectID_PlugIn;
            return noErr;
        case kAudioObjectPropertyName:
            *outDataSize = sizeof(CFStringRef);
            *static_cast<CFStringRef*>(outData) = CFSTR("AudioRouter Virtual Device");
            return noErr;
        case kAudioObjectPropertyManufacturer:
            *outDataSize = sizeof(CFStringRef);
            *static_cast<CFStringRef*>(outData) = CFSTR("AudioRouter");
            return noErr;
        case kAudioDevicePropertyDeviceUID:
            *outDataSize = sizeof(CFStringRef);
            *static_cast<CFStringRef*>(outData) = CFSTR("AudioRouterVirtualDevice-UID");
            return noErr;
        case kAudioDevicePropertyModelUID:
            *outDataSize = sizeof(CFStringRef);
            *static_cast<CFStringRef*>(outData) = CFSTR("AudioRouterVirtualDevice-ModelUID");
            return noErr;
        case kAudioDevicePropertyTransportType:
            *outDataSize = sizeof(UInt32);
            *static_cast<UInt32*>(outData) = kAudioDeviceTransportTypeVirtual;
            return noErr;
        case kAudioDevicePropertyClockDomain:
            *outDataSize = sizeof(UInt32);
            *static_cast<UInt32*>(outData) = 0;
            return noErr;
        case kAudioDevicePropertyDeviceIsAlive:
            *outDataSize = sizeof(UInt32);
            *static_cast<UInt32*>(outData) = 1;
            return noErr;
        case kAudioDevicePropertyDeviceIsRunning:
            *outDataSize = sizeof(UInt32);
            *static_cast<UInt32*>(outData) = atomic_load(&gState.ioRunning) ? 1 : 0;
            return noErr;
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            *outDataSize = sizeof(UInt32);
            *static_cast<UInt32*>(outData) = 1;
            return noErr;
        case kAudioDevicePropertyLatency:
            *outDataSize = sizeof(UInt32);
            *static_cast<UInt32*>(outData) = 0;
            return noErr;
        case kAudioDevicePropertySafetyOffset:
            *outDataSize = sizeof(UInt32);
            *static_cast<UInt32*>(outData) = gState.safetyOffset;
            return noErr;
        case kAudioDevicePropertyZeroTimeStampPeriod:
            *outDataSize = sizeof(UInt32);
            *static_cast<UInt32*>(outData) = 2048;
            return noErr;
        case kAudioDevicePropertyIsHidden:
            *outDataSize = sizeof(UInt32);
            *static_cast<UInt32*>(outData) = 0;
            return noErr;
        case kAudioDevicePropertyRelatedDevices:
            *outDataSize = sizeof(AudioObjectID);
            *static_cast<AudioObjectID*>(outData) = kObjectID_Device;
            return noErr;
        case kAudioDevicePropertyStreams:
            if (inAddress->mScope == kAudioObjectPropertyScopeOutput) {
                *outDataSize = sizeof(AudioObjectID);
                *static_cast<AudioObjectID*>(outData) = kObjectID_Stream_Output;
            } else {
                *outDataSize = 0;
            }
            return noErr;
        case kAudioObjectPropertyControlList:
            *outDataSize = 2 * sizeof(AudioObjectID);
            static_cast<AudioObjectID*>(outData)[0] = kObjectID_Volume_Output_L;
            static_cast<AudioObjectID*>(outData)[1] = kObjectID_Volume_Output_R;
            return noErr;
        case kAudioDevicePropertyNominalSampleRate:
            *outDataSize = sizeof(Float64);
            *static_cast<Float64*>(outData) = gState.sampleRate;
            return noErr;
        case kAudioDevicePropertyAvailableNominalSampleRates: {
            *outDataSize = sizeof(AudioValueRange);
            AudioValueRange* r = static_cast<AudioValueRange*>(outData);
            r->mMinimum = kDevice_SampleRate;
            r->mMaximum = kDevice_SampleRate;
            return noErr;
        }
        default: return kAudioHardwareUnknownPropertyError;
        }

    // ---- Stream ----
    case kObjectID_Stream_Output: {
        AudioStreamBasicDescription asbd;
        FillASBD(&asbd);
        switch (inAddress->mSelector) {
        case kAudioObjectPropertyBaseClass:
            *outDataSize = sizeof(AudioClassID);
            *static_cast<AudioClassID*>(outData) = kAudioObjectClassID;
            return noErr;
        case kAudioObjectPropertyClass:
            *outDataSize = sizeof(AudioClassID);
            *static_cast<AudioClassID*>(outData) = kAudioStreamClassID;
            return noErr;
        case kAudioObjectPropertyOwner:
            *outDataSize = sizeof(AudioObjectID);
            *static_cast<AudioObjectID*>(outData) = kObjectID_Device;
            return noErr;
        case kAudioObjectPropertyName:
            *outDataSize = sizeof(CFStringRef);
            *static_cast<CFStringRef*>(outData) = CFSTR("Output Stream");
            return noErr;
        case kAudioStreamPropertyIsActive:
            *outDataSize = sizeof(UInt32);
            *static_cast<UInt32*>(outData) = 1;
            return noErr;
        case kAudioStreamPropertyDirection:
            *outDataSize = sizeof(UInt32);
            *static_cast<UInt32*>(outData) = 0; // output
            return noErr;
        case kAudioStreamPropertyTerminalType:
            *outDataSize = sizeof(UInt32);
            *static_cast<UInt32*>(outData) = kAudioStreamTerminalTypeSpeaker;
            return noErr;
        case kAudioStreamPropertyStartingChannel:
            *outDataSize = sizeof(UInt32);
            *static_cast<UInt32*>(outData) = 1;
            return noErr;
        case kAudioStreamPropertyLatency:
            *outDataSize = sizeof(UInt32);
            *static_cast<UInt32*>(outData) = 0;
            return noErr;
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            *outDataSize = sizeof(AudioStreamBasicDescription);
            *static_cast<AudioStreamBasicDescription*>(outData) = asbd;
            return noErr;
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: {
            *outDataSize = sizeof(AudioStreamRangedDescription);
            AudioStreamRangedDescription* rd =
                static_cast<AudioStreamRangedDescription*>(outData);
            rd->mFormat = asbd;
            rd->mSampleRateRange.mMinimum = kDevice_SampleRate;
            rd->mSampleRateRange.mMaximum = kDevice_SampleRate;
            return noErr;
        }
        default: return kAudioHardwareUnknownPropertyError;
        }
    }

    default:
        return kAudioHardwareBadObjectError;
    }
}

// ---------------------------------------------------------------------------
// SetPropertyData
// ---------------------------------------------------------------------------
static OSStatus Object_SetPropertyData(AudioServerPlugInDriverRef /*inDriver*/,
                                       AudioObjectID inObjectID,
                                       pid_t /*inClientPID*/,
                                       const AudioObjectPropertyAddress* inAddress,
                                       UInt32 /*inQualifierDataSize*/,
                                       const void* /*inQualifierData*/,
                                       UInt32 inDataSize,
                                       const void* inData)
{
    if (inObjectID == kObjectID_Device) {
        if (inAddress->mSelector == kAudioDevicePropertyNominalSampleRate) {
            Float64 rate = *static_cast<const Float64*>(inData);
            pthread_mutex_lock(&gState.mutex);
            gState.sampleRate = rate;
            pthread_mutex_unlock(&gState.mutex);
            return noErr;
        }
        if (inAddress->mSelector == kARPropertyRouteProcess) {
            if (inDataSize < sizeof(ARRouteCommand)) return kAudioHardwareBadPropertySizeError;
            const ARRouteCommand* cmd = static_cast<const ARRouteCommand*>(inData);
            return RouteProcessToDevice(cmd->pid, cmd->deviceID);
        }
    }
    return kAudioHardwareUnknownPropertyError;
}

// ---------------------------------------------------------------------------
// I/O
// ---------------------------------------------------------------------------
static OSStatus Device_StartIO(AudioServerPlugInDriverRef /*inDriver*/,
                               AudioObjectID /*inDeviceObjectID*/,
                               UInt32 /*inClientID*/)
{
    AR_LOG("StartIO");
    gState.anchorHostTime   = mach_absolute_time();
    gState.anchorSampleTime = 0.0;
    atomic_store(&gState.ioRunning, true);
    return noErr;
}

static OSStatus Device_StopIO(AudioServerPlugInDriverRef /*inDriver*/,
                              AudioObjectID /*inDeviceObjectID*/,
                              UInt32 /*inClientID*/)
{
    AR_LOG("StopIO");
    atomic_store(&gState.ioRunning, false);
    return noErr;
}

static OSStatus Device_GetZeroTimeStamp(AudioServerPlugInDriverRef /*inDriver*/,
                                        AudioObjectID /*inDeviceObjectID*/,
                                        UInt32 /*inClientID*/,
                                        Float64* outSampleTime,
                                        UInt64*  outHostTime,
                                        UInt64*  outSeed)
{
    // Simple monotonic clock: advance by 2048 frames per period.
    const UInt32 kPeriodFrames = 2048;

    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);

    UInt64 now    = mach_absolute_time();
    UInt64 elapsed = now - gState.anchorHostTime;
    // Convert elapsed mach time to nanoseconds, then to samples.
    double elapsedNs = (double)elapsed * tb.numer / tb.denom;
    double elapsedSamples = elapsedNs * gState.sampleRate / 1.0e9;

    UInt64 period = (UInt64)(elapsedSamples / kPeriodFrames);

    *outSampleTime = period * kPeriodFrames;
    // Convert back to host time.
    double periodNs = (*outSampleTime / gState.sampleRate) * 1.0e9;
    *outHostTime    = gState.anchorHostTime +
                      (UInt64)(periodNs * tb.denom / tb.numer);
    *outSeed        = 1;
    return noErr;
}

static OSStatus Device_WillDoIOOperation(AudioServerPlugInDriverRef /*inDriver*/,
                                         AudioObjectID /*inDeviceObjectID*/,
                                         UInt32 /*inClientID*/,
                                         UInt32 inOperationID,
                                         Boolean* outWillDo,
                                         Boolean* outWillDoInPlace)
{
    *outWillDo        = (inOperationID == kAudioServerPlugInIOOperationWriteMix);
    *outWillDoInPlace = true;
    return noErr;
}

static OSStatus Device_BeginIOOperation(AudioServerPlugInDriverRef /*inDriver*/,
                                        AudioObjectID /*inDeviceObjectID*/,
                                        UInt32 /*inClientID*/,
                                        UInt32 /*inOperationID*/,
                                        UInt32 /*inIOBufferFrameSize*/,
                                        const AudioServerPlugInIOCycleInfo* /*inIOCycleInfo*/)
{ return noErr; }

static OSStatus Device_DoIOOperation(AudioServerPlugInDriverRef /*inDriver*/,
                                     AudioObjectID /*inDeviceObjectID*/,
                                     AudioObjectID /*inStreamObjectID*/,
                                     UInt32 /*inClientID*/,
                                     UInt32 /*inOperationID*/,
                                     UInt32 /*inIOBufferFrameSize*/,
                                     const AudioServerPlugInIOCycleInfo* /*inIOCycleInfo*/,
                                     void* /*ioMainBuffer*/,
                                     void* /*ioSecondaryBuffer*/)
{
    // Pass-through: audio data is already in ioMainBuffer.
    // A future enhancement would forward it to a physical device via AudioDeviceIOProcID.
    return noErr;
}

static OSStatus Device_EndIOOperation(AudioServerPlugInDriverRef /*inDriver*/,
                                      AudioObjectID /*inDeviceObjectID*/,
                                      UInt32 /*inClientID*/,
                                      UInt32 /*inOperationID*/,
                                      UInt32 /*inIOBufferFrameSize*/,
                                      const AudioServerPlugInIOCycleInfo* /*inIOCycleInfo*/)
{ return noErr; }
