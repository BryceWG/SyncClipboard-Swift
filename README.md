# SyncClipboard Swift

Native macOS rewrite of SyncClipboard focused on low-memory clipboard sync.

## Scope

- macOS only
- SwiftUI + AppKit menu bar app
- Remote self-hosted SyncClipboard server only
- Core clipboard sync only
- Text sync
- Basic image sync using PNG transfer

## Not Included

- Clipboard history
- File sync
- WebDAV or S3 accounts
- Built-in server
- Hotkeys
- Update checker
- Image compatibility enhancements

## Repository Layout

- `legacy/dotnet-v3/`: archived .NET/Avalonia codebase kept for reference before removal
- `Sources/SyncClipboardKit/`: reusable app logic
- `Sources/SyncClipboardApp/`: macOS app entry, menu bar UI, settings window
- `Tests/SyncClipboardTests/`: unit tests

## Protocol Compatibility

This client keeps compatibility with the current self-hosted SyncClipboard server surface:

- `GET /api/time`
- `GET /SyncClipboard.json`
- `PUT /SyncClipboard.json`
- `GET /file/{dataName}`
- `PUT /file/{dataName}`
- `GET/POST /SyncClipboardHub/negotiate`
- `WS/SSE/LongPolling /SyncClipboardHub`

The current implementation uses the official Swift SignalR client for realtime remote updates and keeps a one-shot HTTP refresh path for explicit manual syncs.

## Build

```bash
swift test
swift run SyncClipboard-Swift
```

## Package

Generate a signed local `.app` bundle and a zip archive:

```bash
zsh build/macos/package_app.sh
```

The script:

- archives the Swift package with `xcodebuild`
- wraps the archived universal binary in `SyncClipboard-Swift.app`
- injects `Info.plist` and the macOS icon
- applies ad-hoc signing
- emits `dist/SyncClipboard-Swift.app`
- emits `dist/SyncClipboard-Swift-0.1.0-macOS.zip`

You can override versions at packaging time:

```bash
MARKETING_VERSION=0.1.0 BUILD_VERSION=20260407010101 zsh build/macos/package_app.sh
```
