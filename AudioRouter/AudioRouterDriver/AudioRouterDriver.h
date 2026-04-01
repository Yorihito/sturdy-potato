#pragma once

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>

// ---------------------------------------------------------------------------
// Plugin entry point
// The HAL calls this function to obtain the plugin interface vtable.
// ---------------------------------------------------------------------------
extern "C" void* AudioServerPlugInMain(CFAllocatorRef inAllocator,
                                       CFUUIDRef      inRequestedTypeUUID);

// ---------------------------------------------------------------------------
// UUIDs
// ---------------------------------------------------------------------------

// Plugin type UUID  – matches CFBundleIdentifier-derived type
#define kAudioRouterDriver_PlugInUUID \
    CFUUIDGetConstantUUIDWithBytes(NULL, \
        0xA1,0xB2,0xC3,0xD4, 0xE5,0xF6, 0x78,0x90, \
        0xAB,0xCD, 0xEF,0x12,0x34,0x56,0x78,0x90)

// Virtual device UUID
#define kAudioRouterDriver_DeviceUUID \
    CFUUIDGetConstantUUIDWithBytes(NULL, \
        0xB2,0xC3,0xD4,0xE5, 0xF6,0x78,0x90,0xAB, \
        0xCD,0xEF, 0x12,0x34,0x56,0x78,0x90,0xA1)

// ---------------------------------------------------------------------------
// Object IDs (compile-time constants used as AudioObjectID values)
// ---------------------------------------------------------------------------
enum : AudioObjectID {
    kObjectID_PlugIn       = kAudioObjectPlugInObject,   // 1
    kObjectID_Device       = 2,
    kObjectID_Stream_Output = 3,
    kObjectID_Volume_Output_L = 4,
    kObjectID_Volume_Output_R = 5,
};

// ---------------------------------------------------------------------------
// Device constants
// ---------------------------------------------------------------------------
static const UInt32  kDevice_SampleRate      = 48000;
static const UInt32  kDevice_ChannelsPerFrame = 2;
static const UInt32  kDevice_BitsPerChannel  = 32;
static const UInt32  kDevice_BytesPerFrame   =
    kDevice_ChannelsPerFrame * (kDevice_BitsPerChannel / 8u);
static const UInt32  kDevice_BytesPerPacket  = kDevice_BytesPerFrame;
static const UInt32  kDevice_FramesPerPacket = 1;

// ---------------------------------------------------------------------------
// Custom property: per-process output device routing
// Object:   kObjectID_Device
// Selector: kARPropertyRouteProcess ('rout')
// Scope:    kAudioObjectPropertyScopeGlobal
// Element:  kAudioObjectPropertyElementMain
// Data:     ARRouteCommand (8 bytes)
//
// The main app writes this property; the plugin (running inside coreaudiod)
// calls kAudioProcessPropertyDevices on behalf of the client process.
// ---------------------------------------------------------------------------
#define kARPropertyRouteProcess  ((AudioObjectPropertySelector)0x726F7574u) // 'rout'

struct ARRouteCommand {
    int32_t  pid;       // target process PID (pid_t)
    uint32_t deviceID;  // AudioDeviceID to assign
};
