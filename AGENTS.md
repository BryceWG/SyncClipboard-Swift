# AGENTS

## Project Goal

This repository is a native macOS rewrite of the SyncClipboard desktop client.

Primary goals:

- macOS only
- Swift implementation
- low memory footprint
- minimal menu bar UI
- self-hosted server account configuration
- core clipboard synchronization only

Do not re-introduce the broad feature surface from the legacy .NET client unless explicitly requested.

## Scope Boundaries

Keep:

- server URL / username / password configuration
- connection test
- realtime clipboard sync against the official SyncClipboard server
- automatic text sync
- manual image / file sync through the server history API
  (`Sync Images/Files` menu action and its configurable global shortcut)
- simple menu bar status UI

Deliberately excluded unless the user asks for them:

- clipboard history UI / local history database
  (the history API is only a transport for manual binary sync)
- WebDAV / S3 / third-party account types
- built-in server features
- updater / release feed logic
- image compatibility enhancement chains
- broad settings surface copied from the legacy app

## Repository Layout

- `Sources/SyncClipboardApp/`
  macOS UI entrypoint, menu bar controller, settings window
- `Sources/SyncClipboardKit/`
  sync logic, networking, SignalR realtime layer, persistence
- `Tests/SyncClipboardTests/`
  unit tests
- `build/macos/`
  packaging script, plist template, app icon
- `Resources/zh-Hans.lproj/Localizable.strings`
  Chinese translations. English is the development region and the translation
  keys, so only `zh-Hans.lproj` exists. It is bundled as a folder reference
  (see `project.yml`), so keep the `.lproj` directory layout.
  The SwiftPM executable (`swift run`) does not see these resources and
  always falls back to English.
- `project.yml`
  XcodeGen source of truth for the native Xcode project
- `SyncClipboard-Swift.xcodeproj/`
  generated native Xcode project for macOS app development
- `legacy/dotnet-v3/`
  archived old codebase for reference only

Do not make functional changes inside `legacy/dotnet-v3/` unless the user explicitly asks for legacy work.

## Build And Test

Local development:

```bash
swift build
swift test
swift run SyncClipboard-Swift
open SyncClipboard-Swift.xcodeproj
```

Package a local `.app` bundle after a full development cycle:

```bash
zsh build/macos/package_app.sh
```

Packaged outputs:

- `dist/SyncClipboard-Swift.app`
- `dist/SyncClipboard-Swift-<version>-macOS.dmg`

Important:

- `project.yml` is the editable source of truth for the Xcode project
- regenerate the project with `xcodegen generate` after changing project structure
- packaging is driven by the native Xcode app target via `build/macos/package_app.sh`

## Runtime Architecture

### App Layer

- `AppDelegate` owns the application lifecycle
- `StatusMenuController` owns the menu bar item and menu actions
- `SettingsWindowController` presents the SwiftUI settings screen

### Core Layer

- `AppModel` is the central state container used by the UI
- `SyncCoordinator` owns upload / download decisions: automatic text sync plus
  the history-driven manual image/file transfer
- `ClipboardService` reads and writes the macOS pasteboard; `ClipboardMonitor`
  polls `changeCount` and records observation times for manual-sync event dating
- `SyncSnapshotTracker` suppresses immediate upload/download echo loops
- `SyncClipboardHTTPClient` handles REST endpoints
  (current profile, file payloads, history API)
- `SignalRRealtimeClient` handles realtime server notifications

## Server Compatibility Contract

The Swift client currently assumes the official self-hosted server surface:

- `GET /api/time`
- `GET /SyncClipboard.json`
- `PUT /SyncClipboard.json`
- `GET /file/{dataName}`
- `PUT /file/{dataName}`
- `GET /api/history/{profileId}`
- `POST /api/history/query` (form-encoded fields; fixed page size 50)
- `POST /api/history` (multipart; metadata fields first, `data` part last)
- `GET /api/history/{profileId}/data`
- `POST /SyncClipboardHub/negotiate?negotiateVersion=1`
- `WS/SSE/LongPolling /SyncClipboardHub`

History details:

- requires SyncClipboard Server 3.1.1+; used only by manual image/file sync
- profile IDs are `{Type}-{UPPERCASE_SHA256}`; the File/Image hash is
  `sha256(fileName + "|" + contentSHA256)`
- multi-file selections are zipped and uploaded as `File` records (not `Group`)
- the client does not subscribe to `RemoteHistoryChanged`; it re-queries the
  server on every manual action
- automatic text sync never calls the history API; manual binary sync never
  writes `/SyncClipboard.json`

SignalR details:

- hub path: `/SyncClipboardHub`
- server event consumed by the client: `RemoteProfileChanged`
- authentication: HTTP Basic Auth header
- implementation dependency: `signalr-client-swift`

When changing protocol handling, keep compatibility with the official server unless the user explicitly approves a breaking change.

## Development Conventions

- Prefer changes inside `SyncClipboardKit` unless the issue is UI-only.
- Add or update unit tests when changing protocol logic, URL construction, request behavior, or tracker behavior.
- Preserve the minimal UI. Avoid adding new settings panels or feature flags without a clear product need.
- All user-facing strings are localized (English keys + zh-Hans translations):
  - SwiftUI literal `Text`/`Toggle`/`Section` titles localize automatically; add the English text as a key in `Resources/zh-Hans.lproj/Localizable.strings`.
  - Dynamic strings use `L10n.tr(...)` in the app target and `NSLocalizedString(..., bundle: .main, ...)` in `SyncClipboardKit`.
  - When adding a user-facing string, always add the zh-Hans entry.
- Be careful with state races between SignalR callbacks, manual refresh, and pasteboard change handling.
- Keep local app identity isolated from the legacy client:
  - app name: `SyncClipboard-Swift`
  - bundle identifier: `xyz.jericx.desktop.syncclipboard.swift`
  - settings folder: `~/Library/Application Support/SyncClipboard-Swift/`
  - keychain service: `xyz.jericx.SyncClipboard-Swift`

## Known Gaps

These are known non-blocking gaps at the current stage:

- no release signing / notarization workflow
- no end-to-end automated test against a live SyncClipboard server
- UI still contains a couple of convenience toggles that are not strictly part of the minimum requested scope
- the manual-sync image provenance and file-download receipt are in-memory only;
  a restart may re-download or re-check the same remote record

## Recent Behavioral Notes

- `Sync Now` should behave as an explicit sync action:
  - attempt local upload first
  - then force a remote refresh
- manual sync should not rely only on the last realtime fingerprint, otherwise it can miss a needed re-apply of unchanged remote content
- `Sync Images/Files` is fully driven by the server history API:
  - register the local binary in history first (event times corrected by the
    server clock), then let the server's latest non-text record win
  - download with a post-download head re-check and at most one retry;
    configuration changes mid-task discard the result
  - an active (non-deleted) history record without data aborts manual sync
    instead of being skipped; the user must delete the broken record server-side
