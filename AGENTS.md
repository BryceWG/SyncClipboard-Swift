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
- text sync
- basic image sync through PNG payloads
- simple menu bar status UI

Deliberately excluded unless the user asks for them:

- clipboard history
- file sync as a user feature
- WebDAV / S3 / third-party account types
- built-in server features
- updater / release feed logic
- hotkeys
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
- `legacy/dotnet-v3/`
  archived old codebase for reference only

Do not make functional changes inside `legacy/dotnet-v3/` unless the user explicitly asks for legacy work.

## Build And Test

Local development:

```bash
swift build
swift test
swift run SyncClipboard-Swift
```

Package a local `.app` bundle:

```bash
zsh build/macos/package_app.sh
```

Packaged outputs:

- `dist/SyncClipboard-Swift.app`
- `dist/SyncClipboard-Swift-<version>-macOS.zip`

Important:

- packaging is currently driven by SwiftPM plus `build/macos/package_app.sh`
- this repo does not yet have a dedicated native `.xcodeproj` app target producing `.app` directly from archive

## Runtime Architecture

### App Layer

- `AppDelegate` owns the application lifecycle
- `StatusMenuController` owns the menu bar item and menu actions
- `SettingsWindowController` presents the SwiftUI settings screen

### Core Layer

- `AppModel` is the central state container used by the UI
- `SyncCoordinator` owns upload / download decisions
- `ClipboardService` reads and writes the macOS pasteboard
- `SyncSnapshotTracker` suppresses immediate upload/download echo loops
- `SyncClipboardHTTPClient` handles REST endpoints
- `SignalRRealtimeClient` handles realtime server notifications

## Server Compatibility Contract

The Swift client currently assumes the official self-hosted server surface:

- `GET /api/time`
- `GET /SyncClipboard.json`
- `PUT /SyncClipboard.json`
- `GET /file/{dataName}`
- `PUT /file/{dataName}`
- `POST /SyncClipboardHub/negotiate?negotiateVersion=1`
- `WS/SSE/LongPolling /SyncClipboardHub`

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
- Be careful with state races between SignalR callbacks, manual refresh, and pasteboard change handling.
- Keep local app identity isolated from the legacy client:
  - app name: `SyncClipboard-Swift`
  - bundle identifier: `xyz.jericx.desktop.syncclipboard.swift`
  - settings folder: `~/Library/Application Support/SyncClipboard-Swift/`
  - keychain service: `xyz.jericx.SyncClipboard-Swift`

## Known Gaps

These are known non-blocking gaps at the current stage:

- no native Xcode app target yet
- no release signing / notarization workflow
- no end-to-end automated test against a live SyncClipboard server
- UI still contains a couple of convenience toggles that are not strictly part of the minimum requested scope

## Recent Behavioral Notes

- `Sync Now` should behave as an explicit sync action:
  - attempt local upload first
  - then force a remote refresh
- manual sync should not rely only on the last realtime fingerprint, otherwise it can miss a needed re-apply of unchanged remote content
