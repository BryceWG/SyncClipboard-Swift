# SyncClipboard Swift

Native macOS rewrite of SyncClipboard focused on low-memory clipboard sync.

## Scope

- macOS only
- SwiftUI + AppKit menu bar app
- Remote self-hosted SyncClipboard server only
- Core clipboard sync only
- Text sync
- Basic image sync using PNG transfer
- Realtime sync via SignalR or periodic HTTP polling
- Launch at Login
- User notifications

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
- `project.yml`: XcodeGen source of truth for the native app target
- `build/macos/package_app.sh`: native archive and packaging script

## Protocol Compatibility

This client keeps compatibility with the current self-hosted SyncClipboard server surface:

- `GET /api/time`
- `GET /SyncClipboard.json`
- `PUT /SyncClipboard.json`
- `GET /file/{dataName}`
- `PUT /file/{dataName}`
- `GET/POST /SyncClipboardHub/negotiate`
- `/SyncClipboardHub` for realtime mode

The current implementation offers two receive modes:

- `Realtime`: uses the official Swift SignalR client for push-style remote updates
- `Polling`: periodically refreshes the remote clipboard over HTTP

Additional runtime controls now available in Settings:

- `Polling Interval`: controls how often polling mode refreshes the clipboard
- `Auto Reconnect`: for realtime mode, reconnects automatically after network loss
- `Auto Retry`: for polling mode, keeps retrying after transient request failures
- wake recovery: when automatic recovery is enabled, the app refreshes or reconnects after the Mac wakes from sleep

## Build System Status

The current build setup is a good native macOS baseline, but it is not yet a full release-grade best-practice pipeline.

What is already in good shape:

- Native macOS app target instead of wrapping a SwiftPM executable
- `project.yml` as the canonical project definition
- XcodeGen-based regeneration of `SyncClipboard-Swift.xcodeproj`
- `xcodebuild` archive packaging for a real `.app`
- Universal binary output for `arm64` and `x86_64`
- Verified local build, test, archive, codesign verification, and Gatekeeper acceptance on the current machine

What still needs to be added for release-grade best practice:

- CI to run `swift test`, `xcodebuild build`, and `xcodebuild test` on every change
- Developer ID Application signing instead of local ad-hoc signing
- Notarization and stapling for external distribution
- A deliberate policy on whether the generated `SyncClipboard-Swift.xcodeproj` should be committed or always regenerated
- Optional release automation for versioning, archive export, notarization, and checksum generation

In short: for local development and internal packaging, the build is already in a solid state; for public distribution, signing and CI are the main missing pieces.

## Prerequisites

- macOS 13 or later
- Xcode installed
- Xcode Command Line Tools installed
- `xcodegen` installed and available in `PATH`

Example:

```bash
xcodegen --version
xcodebuild -version
swift --version
```

## Source of Truth

Do not hand-edit the generated Xcode project as the primary workflow.

- Edit `project.yml`
- Regenerate `SyncClipboard-Swift.xcodeproj`
- Build or archive from the regenerated project

Regenerate the project manually:

```bash
xcodegen generate
```

## Local Development

Run SwiftPM tests first:

```bash
swift test
```

Regenerate and open the native project:

```bash
xcodegen generate
open SyncClipboard-Swift.xcodeproj
```

Build from the command line with the native target:

```bash
xcodebuild \
  -project SyncClipboard-Swift.xcodeproj \
  -scheme SyncClipboard-Swift \
  -configuration Debug \
  -destination 'platform=macOS' \
  build
```

Run the native tests:

```bash
xcodebuild \
  -project SyncClipboard-Swift.xcodeproj \
  -scheme SyncClipboard-Swift \
  -destination 'platform=macOS' \
  test
```

## Packaging

Generate a locally signed `.app` bundle and a zip archive:

```bash
zsh build/macos/package_app.sh
```

The script:

- regenerates the native Xcode project from `project.yml`
- archives the native macOS app target with `xcodebuild`
- verifies the resulting `.app` with `codesign`
- emits `dist/SyncClipboard-Swift.app`
- emits `dist/SyncClipboard-Swift-0.1.0-macOS.zip`

You can override versions at packaging time:

```bash
MARKETING_VERSION=0.1.0 BUILD_VERSION=20260407010101 zsh build/macos/package_app.sh
```

## Verifying Packaged Output

Inspect the packaged app metadata:

```bash
plutil -p dist/SyncClipboard-Swift.app/Contents/Info.plist
```

Verify the app signature:

```bash
codesign --verify --deep --strict --verbose=2 dist/SyncClipboard-Swift.app
codesign -dv --verbose=4 dist/SyncClipboard-Swift.app
```

Check Gatekeeper assessment on the local machine:

```bash
spctl -a -t exec -vv dist/SyncClipboard-Swift.app
```

Check binary architectures:

```bash
lipo -archs dist/SyncClipboard-Swift.app/Contents/MacOS/SyncClipboard-Swift
```

## Runtime Notes

- This is a menu bar app with a native Dock presence by default.
- The Dock icon can be hidden at runtime from Settings.
- The settings UI is opened from the menu bar icon, or automatically on first launch when server configuration is missing.
- Launch at Login is expected to work most reliably after the app is placed in `/Applications`.
- Notifications are requested at runtime when notifications are enabled.

## Release Checklist

For a real external release, the recommended next steps are:

1. Add CI for native build and test validation.
2. Replace ad-hoc signing with Developer ID Application signing.
3. Add notarization and stapling.
4. Decide whether to ship the generated `.xcodeproj` or regenerate it in CI and release scripts only.
