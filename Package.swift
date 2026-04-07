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
    dependencies: [
        .package(url: "https://github.com/dotnet/signalr-client-swift", .upToNextMinor(from: "1.0.0")),
    ],
    targets: [
        .executableTarget(
            name: "SyncClipboardApp",
            dependencies: ["SyncClipboardKit"]
        ),
        .target(
            name: "SyncClipboardKit",
            dependencies: [
                .product(name: "SignalRClient", package: "signalr-client-swift"),
            ]
        ),
        .testTarget(
            name: "SyncClipboardTests",
            dependencies: ["SyncClipboardKit"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
