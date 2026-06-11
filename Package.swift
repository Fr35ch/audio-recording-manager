// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Clio",
    platforms: [
        .macOS(.v14)  // macOS 14 (Sonoma) minimum, Sequoia compatible
    ],
    products: [
        // Executable app
        .executable(
            name: "Clio",
            targets: ["Clio"]
        ),
    ],
    dependencies: [
        // FluidAudio: Apache-2.0 Swift SDK for on-device speaker
        // diarization (CoreML / Apple Neural Engine). Replaces the
        // pyannote.audio Python subprocess + HuggingFace-token UX.
        // See `docs/no_anonymizer_v2_implementasjon.md` for context —
        // and `FluidDiarizationService.swift` for the Swift wrapper.
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            from: "0.12.4"),
    ],
    targets: [
        // Executable app target (combines all sources)
        .executableTarget(
            name: "Clio",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/Clio",
            linkerSettings: [
                .linkedFramework("MultipeerConnectivity"),
            ]
        ),
        // Unit tests for pure, hardware-independent logic (sidecar parsing,
        // transcript merge, transfer stem matching). Uses `@testable import`
        // to reach internal symbols on the executable target.
        .testTarget(
            name: "ClioTests",
            dependencies: ["Clio"],
            path: "tests/ClioTests"
        ),
    ]
)
