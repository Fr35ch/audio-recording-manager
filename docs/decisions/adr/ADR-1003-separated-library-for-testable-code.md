# ADR-1003: Separated Library for Testable Code

**Status**: Accepted

**Date**: 2025-11-28

**Deciders**: Fredrik Matheson, feature-developer agent

## Context

### Problem Statement

Swift macOS apps built with SwiftUI have testability challenges:
- UI code tightly coupled with business logic
- AppKit/SwiftUI components difficult to unit test
- Main app target may have launch requirements incompatible with testing
- Need for high test coverage on critical business logic

### Forces at Play

**Technical Requirements:**
- Unit testing of business logic without launching full app
- Clear separation between testable and UI-bound code
- Swift Package Manager compatibility for testing
- Maintainable architecture as codebase grows

**Constraints:**
- SwiftUI views cannot be easily unit tested
- Main app requires Info.plist and app bundle structure
- SPM test targets need importable modules

**Assumptions:**
- Business logic can be isolated from UI
- Library code provides most testable value
- UI testing handled separately (integration tests)

## Decision

Split Swift code into **two modules**:

1. **AudioRecordingManagerLib** - Testable business logic library
2. **AudioRecordingManager** - Main app with UI (not unit tested)

### Implementation Details

**Package.swift Structure:**
```swift
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

**Directory Structure:**
```
Sources/
├── AudioRecordingManager/      # Main app (UI, AppDelegate)
│   ├── main.swift
│   └── SVGImageView.swift
└── AudioRecordingManagerLib/   # Testable library
    └── AudioRecordingManagerLib.swift

tests/
└── AudioRecordingManagerTests/
    └── SmokeTests.swift
```

**Library Contents:**
- Audio file validation utilities
- Duration formatting
- File naming conventions
- Configuration helpers
- Any pure business logic

**Test Import:**
```swift
@testable import AudioRecordingManagerLib

class SmokeTests: XCTestCase {
    func testLibraryImports() {
        // Tests can access internal library members
    }
}
```

## Consequences

### Positive

- **Testable Core**: Business logic achieves high coverage
- **Fast Tests**: Library tests run without app launch
- **Clear Boundaries**: Separation enforces good architecture
- **SPM Compatible**: Standard Swift package structure
- **CI Friendly**: `swift test` works without Xcode project

### Negative

- **Maintenance Overhead**: Two targets to maintain
- **Import Complexity**: Must decide what goes in library vs app
- **Duplication Risk**: Some code may exist in both places

### Neutral

- **Build Configuration**: Package.swift alongside build.sh
- **Coverage Metrics**: Only library coverage is meaningful

## Alternatives Considered

### Alternative 1: Single Target with @testable

**Description**: Make main app target testable directly.

**Rejected because**:
- App launch requirements complicate testing
- SwiftUI views still not unit testable
- Slower test execution

### Alternative 2: Xcode Project with Test Target

**Description**: Use Xcode project file instead of SPM.

**Rejected because**:
- Xcode project files are complex and merge-conflict prone
- SPM is more portable and CI-friendly
- Custom build.sh already handles app bundling

### Alternative 3: No Unit Tests (Integration Only)

**Description**: Only test via UI/integration tests.

**Rejected because**:
- Slower feedback loop
- Harder to test edge cases
- Less confidence in business logic

## Real-World Results

**Current Coverage:**
- Library module: Targeted for 80%+ coverage
- Main app: Integration tested manually

**Test Examples:**
```swift
func testAudioValidationRejectsEmptyFile() {
    let result = AudioValidator.validate(fileSize: 0)
    XCTAssertFalse(result.isValid)
}

func testDurationFormattingHandlesHours() {
    let formatted = DurationFormatter.format(seconds: 3661)
    XCTAssertEqual(formatted, "1:01:01")
}
```

## Related Decisions

- ADR-1004: Pre-commit Hooks as Quality Gate
- ADR-1010: Two-Layer Build Strategy

## References

- `Package.swift` - Package definition
- `Sources/AudioRecordingManagerLib/` - Library code
- `tests/AudioRecordingManagerTests/` - Test suite
- `docs/TESTING.md` - Testing workflow documentation

## Revision History

- 2025-11-28: Initial decision (Accepted)

---

**Template Version**: 1.1.0
**Project**: Agentive Starter Kit / Audio Recording Manager
