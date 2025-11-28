# ARM-0001: CI/CD and TDD Infrastructure Setup

**Status**: Todo
**Priority**: critical
**Assigned To**: feature-developer
**Estimated Effort**: 3-4 hours
**Created**: 2025-11-28
**Phase**: 0 (Foundation - blocks all other work)

## Overview

Set up the testing and CI/CD infrastructure for Audio Recording Manager so that all future development follows Test-Driven Development (TDD) practices. This foundational task **must be completed before any feature implementation** begins.

**Why this matters**: TDD catches bugs early, documents expected behavior, and makes refactoring safe. Setting this up first ensures good habits from day one and prevents accumulating untested code.

**Why feature-developer**: Planner coordinates and assigns tasks. Feature-developer implements infrastructure code. This is an implementation task.

## Context: Swift/iOS Project

This is a Swift-based audio recording application. The infrastructure will focus on:
- Swift Package Manager for dependencies
- XCTest for unit/UI testing
- GitHub Actions for CI with Xcode
- Pre-commit hooks adapted for Swift (SwiftLint, SwiftFormat)

## Existing Assets to Leverage

The starter kit includes these files - **adapt them, don't replace**:

| File | Status | Action |
|------|--------|--------|
| `tests/test_template.py` | ✅ Exists | Reference only (Python-specific) |
| `.pre-commit-config.yaml` | ✅ Exists | Adapt for Swift (add SwiftLint/SwiftFormat) |
| `tests/` directory | ✅ Exists | Use for test documentation |
| `.github/workflows/ci.yml` | ❌ Missing | Create CI workflow for Xcode |

## Requirements

### Must Have
- [ ] **Pre-flight verification**: Run verification script before starting
- [ ] **Xcode project/workspace**: Verify or create project structure
- [ ] **Swift Package Manager**: Configure dependencies (if needed)
- [ ] **Adapt pre-commit**: Update `.pre-commit-config.yaml` for Swift
- [ ] **Install hooks**: Run `pre-commit install`
- [ ] **Smoke test**: Create basic XCTest suite to verify project structure
- [ ] **CI workflow**: Create `.github/workflows/ci.yml` for Xcode Cloud or GitHub Actions
- [ ] **Documentation**: Create `docs/TESTING.md`

### Should Have
- [ ] Test coverage reporting configured (>70% target)
- [ ] Pre-commit runs fast linting checks (<30 seconds)
- [ ] CI provides clear failure messages
- [ ] SwiftLint configured with project standards

### Nice to Have
- [ ] Test results summary in CI output
- [ ] Code coverage badge in README
- [ ] SwiftFormat auto-formatting

## Pre-Flight Verification (MANDATORY)

⚠️ **STOP**: Do not proceed with implementation until all pre-flight checks pass.

### Step 0: Create Verification Script

Create `scripts/verify-setup.sh`:

```bash
#!/bin/bash
# Pre-flight verification for TDD infrastructure setup (Swift)

echo "🔍 Verifying prerequisites..."
echo

ERRORS=0

# Check Xcode installation
echo "Checking Xcode..."
if xcodebuild -version 2>/dev/null; then
    echo "✅ Xcode detected"
else
    echo "❌ Xcode not installed or not in PATH"
    echo "   Install from: https://developer.apple.com/xcode/"
    ERRORS=$((ERRORS + 1))
fi

# Check Swift version
echo "Checking Swift version..."
if swift --version 2>/dev/null | grep -qE "Swift version [5-9]"; then
    echo "✅ Swift 5+ detected"
else
    echo "❌ Swift 5+ required"
    ERRORS=$((ERRORS + 1))
fi

# Check git configuration
echo "Checking git configuration..."
if git config user.name > /dev/null 2>&1 && git config user.email > /dev/null 2>&1; then
    echo "✅ Git configured"
else
    echo "❌ Git not configured"
    echo "   Run: git config --global user.name \"Your Name\""
    echo "   Run: git config --global user.email \"you@example.com\""
    ERRORS=$((ERRORS + 1))
fi

# Check for Python (for pre-commit)
echo "Checking Python (for pre-commit)..."
if python3 --version 2>/dev/null; then
    echo "✅ Python 3 detected"
else
    echo "❌ Python 3 required for pre-commit"
    ERRORS=$((ERRORS + 1))
fi

# Verify project structure
echo "Checking project structure..."
for item in "README.md" ".agent-context"; do
    if [ -e "$item" ]; then
        echo "✅ $item exists"
    else
        echo "❌ $item not found"
        ERRORS=$((ERRORS + 1))
    fi
done

# Check existing files
echo "Checking existing assets..."
[ -f ".pre-commit-config.yaml" ] && echo "✅ .pre-commit-config.yaml exists" || echo "⚠️  .pre-commit-config.yaml missing"

# Summary
echo
if [ $ERRORS -eq 0 ]; then
    echo "✅ All prerequisites met! Ready to proceed."
    exit 0
else
    echo "❌ $ERRORS prerequisite(s) failed. Fix before proceeding."
    exit 1
fi
```

Make executable and run:

```bash
mkdir -p scripts
chmod +x scripts/verify-setup.sh
./scripts/verify-setup.sh
```

**If verification fails**, STOP and fix issues before proceeding to Step 1.

## Implementation Steps

### Step 1: Create or Verify Xcode Project

**Option A: If Xcode project already exists**
```bash
# Verify project structure
ls *.xcodeproj || ls *.xcworkspace
xcodebuild -list  # List schemes and targets
```

**Option B: If creating new project**
```bash
# Create project via Xcode or use swift package init
mkdir -p AudioRecordingManager
cd AudioRecordingManager
swift package init --type executable
# Or: Create via Xcode GUI (File > New > Project > iOS App)
```

**Error Handling:**

| Error | Cause | Solution |
|-------|-------|----------|
| `Project not found` | Wrong directory | `cd` to project root |
| `xcodebuild: command not found` | Xcode not installed | Install Xcode from App Store |
| `No such scheme` | Invalid scheme name | Run `xcodebuild -list` to see available schemes |

**Verification:**
```bash
xcodebuild -list && echo "✅ Xcode project configured"
```

---

### Step 2: Configure Swift Package Dependencies (if needed)

If using SwiftLint, SwiftFormat, or other tools via SPM:

Create or update `Package.swift`:

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AudioRecordingManager",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(
            name: "AudioRecordingManager",
            targets: ["AudioRecordingManager"]),
    ],
    dependencies: [
        // Add dependencies here if needed
    ],
    targets: [
        .target(
            name: "AudioRecordingManager",
            dependencies: []),
        .testTarget(
            name: "AudioRecordingManagerTests",
            dependencies: ["AudioRecordingManager"]),
    ]
)
```

**Verification:**
```bash
swift build && echo "✅ Swift package builds"
```

---

### Step 3: Install SwiftLint (Recommended)

```bash
# Install via Homebrew
brew install swiftlint

# Or add to Xcode build phase:
# Build Phases > New Run Script Phase:
# if which swiftlint >/dev/null; then
#   swiftlint
# fi
```

Create `.swiftlint.yml`:

```yaml
# SwiftLint Configuration for Audio Recording Manager
disabled_rules:
  - trailing_whitespace
opt_in_rules:
  - empty_count
  - missing_docs
included:
  - Sources
  - Tests
excluded:
  - Pods
  - .build
line_length: 120
```

**Error Handling:**

| Error | Cause | Solution |
|-------|-------|----------|
| `swiftlint: command not found` | Not installed | `brew install swiftlint` |
| `YAML parsing error` | Invalid config | Validate YAML syntax |

**Verification:**
```bash
swiftlint version && echo "✅ SwiftLint installed"
swiftlint lint && echo "✅ SwiftLint passes"
```

---

### Step 4: Adapt `.pre-commit-config.yaml` for Swift

Replace Python-specific hooks with Swift tools:

```yaml
repos:
  # Basic file checks (keep these)
  - repo: https://github.com/pre-commit/pre-commit-hooks
    rev: v4.5.0
    hooks:
      - id: trailing-whitespace
      - id: end-of-file-fixer
      - id: check-yaml
      - id: check-added-large-files

  # SwiftLint
  - repo: local
    hooks:
      - id: swiftlint
        name: SwiftLint
        entry: swiftlint lint --strict
        language: system
        files: \.swift$
        pass_filenames: false

  # Optional: SwiftFormat
  # - repo: local
  #   hooks:
  #     - id: swiftformat
  #       name: SwiftFormat
  #       entry: swiftformat --lint .
  #       language: system
  #       files: \.swift$
  #       pass_filenames: false
```

**Error Handling:**

| Error | Cause | Solution |
|-------|-------|----------|
| `YAML parsing error` | Bad indentation | Use 2-space indentation |
| `swiftlint: command not found` | Not installed | `brew install swiftlint` |

**Verification:**
```bash
python3 -c "import yaml; yaml.safe_load(open('.pre-commit-config.yaml'))" && echo "✅ Valid YAML"
```

---

### Step 5: Create Smoke Tests

Create smoke tests in your XCTest suite:

**If using Xcode project:**
- Add test target if missing (File > New > Target > Unit Testing Bundle)
- Create `SmokeTests.swift`:

```swift
import XCTest

class SmokeTests: XCTestCase {

    func testProjectStructure() {
        // Verify basic project setup
        XCTAssertTrue(true, "Project compiles and tests run")
    }

    func testSwiftVersion() {
        // Verify Swift version
        #if swift(>=5.0)
        XCTAssertTrue(true, "Swift 5+ detected")
        #else
        XCTFail("Swift 5+ required")
        #endif
    }

    func testXcodeVersion() {
        // Basic environment check
        let version = ProcessInfo.processInfo.operatingSystemVersion
        XCTAssertGreaterThanOrEqual(version.majorVersion, 10, "macOS 10+ required")
    }
}
```

**Error Handling:**

| Error | Cause | Solution |
|-------|-------|----------|
| `No such module` | Target not linked | Check Test Target's "Target Dependencies" |
| `Test not found` | Wrong test bundle | Verify test target membership |

**Verification:**
```bash
# Run tests via xcodebuild or Xcode
xcodebuild test -scheme AudioRecordingManager -destination 'platform=iOS Simulator,name=iPhone 15'
# OR: Cmd+U in Xcode
```

---

### Step 6: Create GitHub Actions CI

Create `.github/workflows/ci.yml`:

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  test:
    name: Test on iOS
    runs-on: macos-latest

    steps:
      - uses: actions/checkout@v4

      - name: Select Xcode version
        run: sudo xcode-select -s /Applications/Xcode_15.0.app

      - name: Show Xcode version
        run: xcodebuild -version

      - name: Run tests
        run: |
          xcodebuild test \
            -scheme AudioRecordingManager \
            -destination 'platform=iOS Simulator,name=iPhone 15,OS=17.0' \
            -enableCodeCoverage YES \
            CODE_SIGN_IDENTITY="" \
            CODE_SIGNING_REQUIRED=NO

      - name: SwiftLint
        run: |
          brew install swiftlint
          swiftlint lint --strict
```

**Error Handling:**

| Error | Cause | Solution |
|-------|-------|----------|
| `xcodebuild: error` | Invalid scheme/destination | Verify scheme name and iOS version |
| `SwiftLint not found` | Not in CI environment | Install via `brew install swiftlint` |

**Verification:**
```bash
mkdir -p .github/workflows
ls .github/workflows/ci.yml && echo "✅ CI workflow created"
```

---

### Step 7: Install Pre-commit Hooks

```bash
# Install pre-commit (if not installed)
pip3 install pre-commit

# Install hooks
pre-commit install

# Test on all files
pre-commit run --all-files
```

**Error Handling:**

| Error | Cause | Solution |
|-------|-------|----------|
| `pre-commit: command not found` | Not installed | `pip3 install pre-commit` |
| `Hook failed: swiftlint` | Linting issues | Fix issues or adjust `.swiftlint.yml` rules |

**Verification:**
```bash
ls .git/hooks/pre-commit && echo "✅ Hooks installed"
pre-commit run --all-files && echo "✅ All hooks pass"
```

---

### Step 8: Create Testing Documentation

Create `docs/TESTING.md`:

```markdown
# Testing Guide - Audio Recording Manager

## Quick Start

```bash
# Run all tests via Xcode
# Press: Cmd+U

# Or via command line:
xcodebuild test -scheme AudioRecordingManager -destination 'platform=iOS Simulator,name=iPhone 15'

# Run specific test class
xcodebuild test -scheme AudioRecordingManager -only-testing:AudioRecordingManagerTests/SmokeTests
```

## TDD Workflow (Red-Green-Refactor)

1. **RED**: Write a failing test first
2. **GREEN**: Write minimum code to pass
3. **REFACTOR**: Improve while keeping tests green

## Writing Tests

Follow the AAA (Arrange-Act-Assert) pattern:

```swift
func testExample() {
    // Arrange: Set up test data
    let recorder = AudioRecorder()

    // Act: Call the method
    let result = recorder.startRecording()

    // Assert: Verify the result
    XCTAssertTrue(result.isSuccess)
}
```

## Pre-commit Hooks

Hooks run automatically before each commit:
- SwiftLint (code quality)
- Basic file checks

**Skip hooks for WIP commits:**
```bash
SKIP=swiftlint git commit -m "WIP: work in progress"
```

## CI/CD

Tests run automatically on push via GitHub Actions.
View results: https://github.com/[org]/[repo]/actions

## Coverage Targets

- New code: >80% coverage
- Overall: >70% coverage
- Critical paths: >90% coverage

Enable code coverage in Xcode:
1. Edit Scheme > Test
2. Check "Code Coverage"
3. View: Product > Show Code Coverage
```

**Verification:**
```bash
mkdir -p docs
ls docs/TESTING.md && echo "✅ Documentation created"
```

---

## Acceptance Criteria

### Core Setup
- [ ] Pre-flight verification passes (`./scripts/verify-setup.sh`)
- [ ] Tests run successfully (Xcode or `xcodebuild test`)
- [ ] `pre-commit run --all-files` passes
- [ ] GitHub Actions CI workflow exists and runs on push

### Configuration
- [ ] Xcode project/workspace properly configured
- [ ] SwiftLint configured
- [ ] `.pre-commit-config.yaml` adapted for Swift
- [ ] Pre-commit hooks installed

### Documentation
- [ ] `docs/TESTING.md` created
- [ ] TDD process documented

### Quality Gates
- [ ] Pre-commit runs in <30 seconds
- [ ] CI workflow completes in <10 minutes
- [ ] All tests pass on latest iOS simulator

## Success Metrics

**Quantitative**:
- Smoke tests run in <5 seconds
- Pre-commit hooks complete in <30 seconds
- CI workflow completes in <10 minutes

**Qualitative**:
- Developers can write tests following examples
- TDD workflow is clear and documented
- CI failures are actionable

## Dependencies

**Blocks** (cannot start until this completes):
- All feature implementation tasks
- iOS project structure tasks

**Blocked By**:
- None (foundational task)

---

## Implementation Notes (For feature-developer)

### ✅ DO:
- Run pre-flight verification first (Step 0 is MANDATORY)
- Follow steps sequentially (1-8)
- Use error tables for troubleshooting
- Verify each step before proceeding
- Test pre-commit hooks thoroughly

### ❌ DON'T:
- Skip pre-flight verification
- Assume Xcode project exists without checking
- Ignore verification commands
- Proceed if smoke tests fail

### Quality Assurance:
- All steps include error handling tables
- Pre-flight script catches common issues early
- Verification commands confirm each step worked

### After Completion:
Ensure all subsequent feature tasks include:
- Test requirements section
- TDD workflow (Red-Green-Refactor)
- Coverage targets (80%+ for new code)

---

**Template Version**: 3.1.0 (Swift adaptation)
**Purpose**: First task for new Swift/iOS projects to establish TDD practices
