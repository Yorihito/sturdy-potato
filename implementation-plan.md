# 実装計画書：macOS アプリケーション別音声出力切り替えアプリ

## 1. 技術スタック

| 層 | 採用技術 | 理由 |
|----|---------|------|
| 言語 | Swift 6 | Apple Silicon ネイティブ、最新の async/await 対応 |
| UI フレームワーク | SwiftUI + AppKit (NSStatusItem) | メニューバーアプリに必要な AppKit と宣言的 UI の組み合わせ |
| 音声ルーティング | CoreAudio / AudioServerPlugin | 公開 API 内でアプリ単位ルーティングを実現する唯一の手段 |
| 設定永続化 | UserDefaults + Codable | 軽量なプロファイル保存 |
| テスト | XCTest + Swift Testing | ユニット・統合テスト |
| CI/CD | GitHub Actions + Xcode Cloud | 自動ビルド・テスト・公証 |

---

## 2. アーキテクチャ

```
┌─────────────────────────────────────┐
│          UI Layer (SwiftUI)         │
│  MenuBarView / AppListView /        │
│  DevicePickerView / ProfileView     │
└──────────────┬──────────────────────┘
               │ @Observable / Binding
┌──────────────▼──────────────────────┐
│       ViewModel Layer               │
│  AudioRoutingViewModel              │
│  DeviceMonitorViewModel             │
│  ProfileViewModel                   │
└──────────────┬──────────────────────┘
               │ async/await
┌──────────────▼──────────────────────┐
│       Service Layer                 │
│  AudioDeviceService  (CoreAudio)    │
│  AppMonitorService   (NSWorkspace)  │
│  ProfileService      (UserDefaults) │
│  HDMIMonitorService  (IOKit)        │
└──────────────┬──────────────────────┘
               │
┌──────────────▼──────────────────────┐
│       Driver Layer                  │
│  VirtualAudioDriver                 │
│  (AudioServerPlugin / kext-free)    │
└─────────────────────────────────────┘
```

### 2.1 仮想オーディオデバイスによるルーティング

macOS のサンドボックス制限により、アプリケーションの音声ストリームを直接キャプチャ・リダイレクトすることはできない。そのため、以下のアプローチを採用する：

1. **AudioServerPlugin**（`/Library/Audio/Plug-Ins/HAL/`）として仮想オーディオデバイスを実装し、システムにインストールする
2. ユーザーはアプリごとに「仮想デバイス」を出力先に設定する（本アプリが自動設定）
3. 仮想デバイスはバックグラウンドで受け取った音声を、設定された物理デバイスへ転送する

> **注意**：AudioServerPlugin のインストールには管理者権限が必要。初回起動時に認証ダイアログを表示する。

---

## 3. フェーズ別実装計画

### Phase 1：基盤構築（2 週間）

**目標**：CoreAudio デバイス列挙・仮想オーディオドライバの動作確認

| タスク | 担当層 | 完了条件 |
|--------|--------|---------|
| Xcode プロジェクト作成（SwiftUI, macOS target） | - | ビルド成功 |
| AudioServerPlugin テンプレート実装 | Driver | 仮想デバイスがシステムに認識される |
| CoreAudio デバイス一覧取得 (`AudioObjectGetPropertyData`) | Service | 接続デバイス名・UID が取得できる |
| HDMI デバイス判定ロジック（IOKit `kIOAudioOutputClass`） | Service | HDMI デバイスとその他を区別できる |
| NSWorkspace による実行中アプリ一覧取得 | Service | バンドル ID・アイコン・名称が取得できる |

### Phase 2：音声ルーティングコア（2 週間）

**目標**：アプリ→仮想デバイス→物理デバイスの経路を確立

| タスク | 担当層 | 完了条件 |
|--------|--------|---------|
| 仮想デバイスへのアプリ出力割り当て（`kAudioHardwarePropertyDefaultOutputDevice` per-PID） | Service | 指定アプリの音がターゲットデバイスから出る |
| HDMI パススルーモード設定（`kAudioDevicePropertyAvailableNominalSampleRates` / bitstream フラグ） | Service | Dolby/DTS ロゴが AV アンプで点灯する |
| デバイス切断時のフォールバック処理 | Service | HDMI 切断時に自動でデフォルトデバイスへ切り替わる |
| プロファイルの保存・読み込み（Codable → UserDefaults） | Service | アプリ再起動後も設定が保持される |

### Phase 3：UI 実装（2 週間）

**目標**：要件 F-10〜F-15 を満たす UI の完成

| タスク | 担当層 | 完了条件 |
|--------|--------|---------|
| メニューバーアイコン実装（`NSStatusItem`） | UI | クリックでポップオーバーが開く |
| アプリ一覧 + デバイス選択ドロップダウン画面 | UI | 全実行中アプリが表示され、デバイスを選択できる |
| プロファイル管理画面（一覧・追加・削除・即時切り替え） | UI | プロファイルの CRUD 操作が完了する |
| ダークモード / ライトモード対応 | UI | 両モードで視認性に問題がない |
| 初回起動オンボーディング（管理者権限要求フロー含む） | UI | ドライバインストールが案内どおりに完了する |

### Phase 4：品質保証・リリース準備（2 週間）

| タスク | 完了条件 |
|--------|---------|
| ユニットテスト実装（カバレッジ 70% 以上） | `xcodebuild test` 全 PASS |
| パフォーマンス測定（レイテンシ・メモリ） | NF-01, NF-02 を満たす |
| Apple Developer アカウントによる公証 (Notarization) | `xcrun stapler validate` 成功 |
| App Store Connect へのアップロード | 審査提出完了 |
| README・ヘルプドキュメント作成 | 利用者向けドキュメント完成 |

---

## 4. ディレクトリ構成

```
AudioRouter/
├── AudioRouter.xcodeproj
├── AudioRouter/                    # メインアプリ
│   ├── App/
│   │   └── AudioRouterApp.swift    # @main, NSStatusItem セットアップ
│   ├── Views/
│   │   ├── MenuBarView.swift
│   │   ├── AppListView.swift
│   │   ├── DevicePickerView.swift
│   │   ├── ProfileView.swift
│   │   └── OnboardingView.swift
│   ├── ViewModels/
│   │   ├── AudioRoutingViewModel.swift
│   │   ├── DeviceMonitorViewModel.swift
│   │   └── ProfileViewModel.swift
│   ├── Services/
│   │   ├── AudioDeviceService.swift
│   │   ├── AppMonitorService.swift
│   │   ├── HDMIMonitorService.swift
│   │   └── ProfileService.swift
│   ├── Models/
│   │   ├── AudioDevice.swift
│   │   ├── AppEntry.swift
│   │   └── Profile.swift
│   └── Resources/
│       └── Assets.xcassets
├── AudioRouterDriver/              # AudioServerPlugin (仮想オーディオドライバ)
│   ├── AudioRouterDriver.cpp
│   ├── AudioRouterDriver.h
│   └── Info.plist
└── AudioRouterTests/
    ├── AudioDeviceServiceTests.swift
    ├── HDMIMonitorServiceTests.swift
    └── ProfileServiceTests.swift
```

---

## 5. 主要 API・フレームワーク

| API | 用途 |
|-----|------|
| `CoreAudio` (`AudioHardware.h`) | デバイス列挙、デバイスプロパティ取得・設定 |
| `AudioServerPlugin` | 仮想オーディオデバイスの実装 |
| `IOKit` (`IOAudio.framework`) | HDMI デバイス判定、接続状態監視 |
| `NSWorkspace.shared.runningApplications` | 実行中アプリ一覧の取得 |
| `NSWorkspace.didActivateApplicationNotification` | アプリ切り替え検知 |
| `UserDefaults` + `Codable` | プロファイルの永続化 |
| `SwiftUI` + `NSPopover` | メニューバー UI |

---

## 6. リスクと対策

| リスク | 影響度 | 対策 |
|--------|--------|------|
| AudioServerPlugin インストールに管理者権限が必要 | 高 | 初回起動時に分かりやすいガイドを提供。SMJobBless を使用してヘルパーとして登録 |
| macOS アップデートによる API 変更 | 中 | パブリック API のみ使用。マイナーバージョンアップごとにテストを実施 |
| アプリ単位の音声ルーティングの制限（API 制約） | 高 | CoreAudio の per-process default device API（macOS 14+ で改善）を調査・活用 |
| HDMI パススルーフォーマットの機種依存 | 中 | テスト機材（M4 Mac mini + 対応 AV アンプ）での実機テストを Phase 1 で実施 |
| App Store サンドボックスとドライバの共存 | 高 | ドライバのインストールは Installer パッケージ（.pkg）経由とし、アプリ本体は Mac App Store で配布 |

---

## 7. マイルストーン

| マイルストーン | 期間 | 成果物 |
|---------------|------|--------|
| M1: 基盤完了 | Week 1-2 | 仮想ドライバ動作確認、デバイス列挙 |
| M2: ルーティングコア完了 | Week 3-4 | アプリ別音声ルーティング・HDMI パススルー動作 |
| M3: UI 完成 | Week 5-6 | フル機能 UI、プロファイル管理 |
| M4: リリース | Week 7-8 | 公証済みアプリ、App Store 審査提出 |

---

## 8. 参考資料

- [Apple Developer: CoreAudio Overview](https://developer.apple.com/documentation/coreaudio)
- [Apple Developer: Audio Server Plug-In Programming Guide](https://developer.apple.com/library/archive/documentation/MusicAudio/Conceptual/AudioServerPlugin/)
- [Apple Developer: IOAudioFamily Reference](https://developer.apple.com/documentation/kernel/ioaudiofamily)
- [WWDC 2023: What's new in AVFoundation](https://developer.apple.com/videos/play/wwdc2023/10101/)
