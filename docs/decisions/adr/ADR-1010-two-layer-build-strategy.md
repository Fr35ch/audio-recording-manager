# ADR-1010: Two-Layer Build Strategy

**Status**: Accepted

**Date**: 2025-11-28

**Deciders**: Fredrik Matheson, feature-developer agent

## Context

### Problem Statement

Swift macOS apps need both:
1. **Testing infrastructure** - Unit tests via Swift Package Manager
2. **App bundling** - Proper .app bundle with Info.plist, resources, etc.

SPM cannot create .app bundles. Xcode projects are complex and conflict-prone.

### Forces at Play

**Technical Requirements:**
- `swift test` must work for CI/CD
- Final output must be proper macOS .app bundle
- Assets and resources must be included
- App must have correct Info.plist and entitlements

**Constraints:**
- No Xcode project file (avoid merge conflicts)
- Must work in CI without Xcode GUI
- Xcode SDK needed for proper Sequoia window styling

**Assumptions:**
- SPM sufficient for library/test compilation
- Custom script can create proper app bundle
- Both build methods can coexist

## Decision

Implement **two-layer build strategy**:

1. **Swift Package Manager** - For testing and library compilation
2. **Custom build.sh** - For creating .app bundle

### Implementation Details

**Package.swift (Testing Layer):**
```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AudioRecordingManager",
    platforms: [.macOS(.v14)],
    products: [
        .library(
            name: "AudioRecordingManagerLib",
            targets: ["AudioRecordingManagerLib"]
        ),
    ],
    targets: [
        .target(
            name: "AudioRecordingManagerLib",
            path: "Sources/AudioRecordingManagerLib"
        ),
        .testTarget(
            name: "AudioRecordingManagerTests",
            dependencies: ["AudioRecordingManagerLib"],
            path: "tests/AudioRecordingManagerTests"
        ),
    ]
)
```

**build.sh (App Bundle Layer):**
```bash
#!/bin/bash
set -e

APP_NAME="AudioRecordingManager"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

# Create app bundle structure
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Compile with Xcode SDK for proper styling
XCODE_SDK="/Applications/Xcode.app/.../MacOSX.sdk"

if [ -d "$XCODE_SDK" ]; then
    swiftc \
        -o "$APP_BUNDLE/Contents/MacOS/$APP_NAME" \
        Sources/AudioRecordingManager/*.swift \
        -parse-as-library \
        -target arm64-apple-macos15.0 \
        -framework SwiftUI \
        -framework AppKit \
        -sdk "$XCODE_SDK"
else
    # Fallback to Command Line Tools
    swiftc \
        -o "$APP_BUNDLE/Contents/MacOS/$APP_NAME" \
        Sources/AudioRecordingManager/*.swift \
        ...
fi

# Copy Info.plist
cp Info.plist "$APP_BUNDLE/Contents/Info.plist"

# Copy assets
cp -r Assets/* "$APP_BUNDLE/Contents/Resources/"
cp -r Resources/* "$APP_BUNDLE/Contents/Resources/"

# Create PkgInfo
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
```

**CI Workflow Usage:**
```yaml
jobs:
  test:
    steps:
      - name: Run tests
        run: swift test

      - name: Build app bundle
        run: ./build.sh

      - name: Verify app launches
        run: open build/AudioRecordingManager.app
```

**Directory Structure:**
```
├── Package.swift           # SPM: testing
├── build.sh                # App bundling
├── Info.plist              # App metadata
├── Sources/
│   ├── AudioRecordingManager/     # Main app
│   └── AudioRecordingManagerLib/  # Testable library
├── tests/
│   └── AudioRecordingManagerTests/
├── Assets/                 # App assets
└── Resources/              # Additional resources
```

## Consequences

### Positive

- **No Xcode Project**: Avoids complex .xcodeproj merge conflicts
- **CI-Friendly**: Both `swift test` and `./build.sh` work in CI
- **Separation of Concerns**: Testing separate from bundling
- **Flexible**: Can customize build.sh for specific needs
- **SDK Control**: Explicit Xcode SDK usage for proper styling

### Negative

- **Two Build Systems**: Must maintain both Package.swift and build.sh
- **Potential Drift**: Swift files in Package.swift vs build.sh may diverge
- **Manual Resource Handling**: build.sh must know about all resources
- **Xcode Dependency**: Full styling requires Xcode SDK

### Neutral

- **Build Output**: `swift build` output differs from `./build.sh` output
- **Development Workflow**: Run tests with SPM, app with build.sh

## Alternatives Considered

### Alternative 1: Xcode Project Only

**Description**: Use .xcodeproj for both testing and building.

**Rejected because**:
- Xcode projects cause merge conflicts
- Harder to maintain in git
- Requires Xcode GUI for some changes

### Alternative 2: SPM Only

**Description**: Use SPM for everything, manual app bundling.

**Rejected because**:
- SPM cannot create .app bundles
- Would need post-processing anyway

### Alternative 3: CMake/Other Build System

**Description**: Use cross-platform build system.

**Rejected because**:
- Overkill for macOS-only app
- Less Swift ecosystem integration
- Additional learning curve

## Real-World Results

**Build Times:**
- `swift test`: ~15 seconds
- `./build.sh`: ~10 seconds
- Total CI time: ~45 seconds

**Maintenance:**
- Package.swift: Updated when adding test targets
- build.sh: Updated when adding source files or resources

## Related Decisions

- ADR-1003: Separated Library for Testable Code
- ADR-1004: Pre-commit Hooks as Quality Gate

## References

- `Package.swift` - SPM configuration
- `build.sh` - App bundle script
- `Info.plist` - App metadata
- `.github/workflows/ci.yml` - CI configuration

## Revision History

- 2025-11-28: Initial decision (Accepted)

---

**Template Version**: 1.1.0
**Project**: Agentive Starter Kit / Audio Recording Manager
