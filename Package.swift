// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "AudioRecordingManager",
    platforms: [
        .macOS(.v14)  // macOS 14 (Sonoma) minimum, Sequoia compatible
    ],
    products: [
        // Executable app
        .executable(
            name: "AudioRecordingManager",
            targets: ["AudioRecordingManager"]
        ),
    ],
    dependencies: [
        // Add dependencies here if needed
    ],
    targets: [
        // Executable app target (combines all sources)
        .executableTarget(
            name: "AudioRecordingManager",
            dependencies: [],
            path: "Sources/AudioRecordingManager"
        ),
    ]
)
