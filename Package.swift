// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "AudioRecordingManager",
    platforms: [
        .macOS(.v14)  // macOS 14 (Sonoma) minimum, Sequoia compatible
    ],
    products: [
        // Library target for testing (exposes testable types)
        .library(
            name: "AudioRecordingManagerLib",
            targets: ["AudioRecordingManagerLib"]
        ),
    ],
    dependencies: [
        // Add dependencies here if needed
    ],
    targets: [
        // Library target containing testable code
        // Note: The main app uses build.sh with swiftc for full framework support
        // This library contains business logic that can be tested independently
        .target(
            name: "AudioRecordingManagerLib",
            dependencies: [],
            path: "Sources/AudioRecordingManagerLib"
        ),
        // Test target
        .testTarget(
            name: "AudioRecordingManagerTests",
            dependencies: ["AudioRecordingManagerLib"],
            path: "Tests/AudioRecordingManagerTests"
        ),
    ]
)
