# Testing Guide - Audio Recording Manager

This guide covers the testing infrastructure for the Audio Recording Manager macOS application.

## Quick Start

### Run Tests

```bash
# Run all Swift tests (requires Xcode installed)
swift test

# Run with verbose output
swift test -v

# Build only (no tests)
swift build
```

### Pre-commit Hooks

```bash
# Install pre-commit hooks (one-time setup)
pip3 install pre-commit
pre-commit install

# Run all hooks manually
pre-commit run --all-files

# Skip hooks for WIP commits
SKIP_TESTS=1 git commit -m "WIP: work in progress"

# Skip Swift build check
SKIP_SWIFT_BUILD=1 git commit -m "WIP: work in progress"

# Skip SwiftLint only
SKIP=swiftlint git commit -m "message"
```

## Project Structure

```
AudioRecordingManager/
├── Sources/
│   ├── AudioRecordingManager/    # Main app (build.sh)
│   │   ├── main.swift            # App entry point + UI
│   │   └── SVGImageView.swift    # SVG rendering
│   └── AudioRecordingManagerLib/ # Testable library
│       └── AudioRecordingManagerLib.swift
├── Tests/
│   └── AudioRecordingManagerTests/
│       └── SmokeTests.swift      # Basic tests
├── Package.swift                 # Swift Package Manager
├── build.sh                      # App bundle builder
└── .swiftlint.yml               # SwiftLint config
```

### Build Methods

1. **Swift Package Manager** (for testing):
   ```bash
   swift build   # Build library
   swift test    # Run tests
   ```

2. **build.sh** (for full app):
   ```bash
   ./build.sh    # Creates .app bundle with all frameworks
   open build/AudioRecordingManager.app
   ```

## TDD Workflow (Red-Green-Refactor)

Follow Test-Driven Development for all new features:

### 1. RED: Write a failing test first

```swift
func testNewFeature() {
    // Arrange: Set up test data
    let manager = AudioFileManager()

    // Act: Call the method
    let result = manager.processFile("test.wav")

    // Assert: Verify the result
    XCTAssertTrue(result.isSuccess)
}
```

### 2. GREEN: Write minimum code to pass

Implement just enough code to make the test pass. Don't over-engineer.

### 3. REFACTOR: Improve while keeping tests green

Clean up the code while ensuring all tests still pass.

## Writing Tests

### Test File Location

Place tests in `Tests/AudioRecordingManagerTests/`:

```
Tests/AudioRecordingManagerTests/
├── SmokeTests.swift           # Infrastructure tests
├── AudioFileUtilsTests.swift  # Unit tests for utilities
└── IntegrationTests.swift     # Integration tests
```

### Test Naming Convention

Use descriptive names that explain what is being tested:

```swift
func test_formatDuration_withZeroSeconds_returnsZeroMinutes()
func test_isValidAudioExtension_withWavFile_returnsTrue()
func test_isValidAudioExtension_withPdfFile_returnsFalse()
```

### AAA Pattern (Arrange-Act-Assert)

```swift
func testAudioFileValidation() {
    // Arrange: Set up test data
    let path = "recording.wav"

    // Act: Call the method under test
    let isValid = AudioFileUtils.isValidAudioExtension(path)

    // Assert: Verify the result
    XCTAssertTrue(isValid, "WAV files should be valid audio")
}
```

### Testing Asynchronous Code

```swift
func testAsyncOperation() async throws {
    // Arrange
    let manager = AudioRecorder()

    // Act
    let result = try await manager.startRecording()

    // Assert
    XCTAssertTrue(result.isRecording)
}
```

## Pre-commit Hooks

The following hooks run automatically before each commit:

| Hook | Purpose | Skip Command |
|------|---------|--------------|
| `trailing-whitespace` | Remove trailing spaces | - |
| `end-of-file-fixer` | Ensure newline at EOF | - |
| `check-yaml` | Validate YAML syntax | - |
| `black` | Format Python code | `SKIP=black` |
| `swiftlint` | Lint Swift code | `SKIP=swiftlint` |
| `swift-build` | Verify Swift builds | `SKIP_SWIFT_BUILD=1` |
| `pytest-fast` | Run Python tests | `SKIP_TESTS=1` |

### Skipping Hooks

For work-in-progress commits:
```bash
# Skip all tests
SKIP_TESTS=1 git commit -m "WIP: partial implementation"

# Skip specific hooks
SKIP=swiftlint,black git commit -m "WIP"

# Skip Swift build (useful when editing non-Swift files)
SKIP_SWIFT_BUILD=1 git commit -m "docs: update readme"
```

## CI/CD

Tests run automatically on GitHub Actions for:
- Every push to `main`
- Every pull request to `main`

### CI Workflow Jobs

1. **swift-test**: Build and test Swift package on macOS
2. **swiftlint**: Lint Swift code
3. **python-lint**: Lint Python scripts

### Viewing CI Results

```bash
# Check CI status (requires gh CLI)
gh run list

# View specific run
gh run view <run-id>

# View failed logs
gh run view <run-id> --log-failed
```

## Coverage Targets

| Category | Target |
|----------|--------|
| New code | >80% |
| Overall | >70% |
| Critical paths | >90% |

### Enabling Coverage in Xcode

1. Edit Scheme > Test
2. Check "Code Coverage"
3. View: Product > Show Code Coverage

### Coverage in CI

Coverage reports are generated during CI runs. View them in the GitHub Actions artifacts.

## Local Testing Requirements

### Full Testing (with Xcode)

If you have Xcode installed, you can run all tests locally:

```bash
# Switch to Xcode (requires sudo)
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer

# Run tests
swift test
```

### Limited Testing (Command Line Tools only)

Without full Xcode, you can still:
- Build the Swift package: `swift build`
- Build the app: `./build.sh`
- Run SwiftLint: `swiftlint lint`

Tests will run in CI even if they can't run locally.

## Troubleshooting

### "No such module 'XCTest'"

XCTest requires full Xcode, not just Command Line Tools:
```bash
# Check current developer path
xcode-select -p

# If it shows /Library/Developer/CommandLineTools, switch to Xcode:
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

### "SwiftLint not found"

Install SwiftLint via Homebrew:
```bash
brew install swiftlint
```

### Pre-commit Hook Failures

```bash
# See detailed output
pre-commit run --all-files --verbose

# Update hooks to latest versions
pre-commit autoupdate
```

### CI Failures

1. Check the GitHub Actions logs
2. Run locally: `./scripts/verify-swift-setup.sh`
3. Ensure `swift build` succeeds locally

## Adding New Tests

1. Create test file in `Tests/AudioRecordingManagerTests/`
2. Import the module: `@testable import AudioRecordingManagerLib`
3. Write tests following AAA pattern
4. Run `swift test` to verify
5. Commit with passing tests

## Resources

- [XCTest Documentation](https://developer.apple.com/documentation/xctest)
- [Swift Package Manager](https://swift.org/package-manager/)
- [SwiftLint Rules](https://realm.github.io/SwiftLint/rule-directory.html)
- [Pre-commit Hooks](https://pre-commit.com/)
