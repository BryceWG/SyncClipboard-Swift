// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "SyncClipboard",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "SyncClipboardKit",
            targets: ["SyncClipboardKit"]
        ),
        .executable(
            name: "SyncClipboard-Swift",
            targets: ["SyncClipboardApp"]
        ),
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "SyncClipboardApp",
            dependencies: ["SyncClipboardKit"]
        ),
        .target(
            name: "SyncClipboardKit"
        ),
        .testTarget(
            name: "SyncClipboardTests",
            dependencies: ["SyncClipboardKit"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
