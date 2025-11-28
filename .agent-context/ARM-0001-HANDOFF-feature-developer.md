# ARM-0001 Handoff: CI/CD and TDD Infrastructure Setup

**Task File**: `delegation/tasks/2-todo/ARM-0001-tdd-infrastructure.md`
**Target Agent**: feature-developer
**Created**: 2025-11-28
**Priority**: Critical (Phase 0 - blocks all other work)

---

## Project Context (CRITICAL - Read First)

This is a **macOS SwiftUI application** (NOT iOS), currently built via shell script:

### Current State
- **Source Files**: `Sources/AudioRecordingManager/main.swift`, `SVGImageView.swift`
- **Build Method**: `./build.sh` (uses raw `swiftc` compilation)
- **Target**: macOS 15.0 (arm64)
- **Frameworks**: SwiftUI, AppKit, WebKit, CoreWLAN, IOBluetooth, DiskArbitration
- **No Xcode project exists** - you'll need to create one OR use Swift Package Manager
- **Pre-commit**: Currently Python-focused, needs Swift adaptation

### Key Insight
The task spec assumes iOS. **Adapt for macOS**:
- Use macOS simulator/device destinations instead of iOS
- Create `.xcodeproj` or `Package.swift` for project structure
- Test targets should link to macOS, not iOS

---

## Implementation Guidance

### Step 0: Pre-flight Verification
The task includes a verification script template. Create and run it first:
```bash
mkdir -p scripts
# Create scripts/verify-setup.sh (see task file for content)
chmod +x scripts/verify-setup.sh
./scripts/verify-setup.sh
```

### Step 1: Project Structure Decision

**Option A: Xcode Project (Recommended)**
```bash
# Create via Xcode GUI:
# File > New > Project > macOS > App
# Name: AudioRecordingManager
# Add existing Sources/ files to project
```

**Option B: Swift Package Manager**
```bash
# Create Package.swift with macOS target
# See task file for template - change iOS to macOS
```

The current `build.sh` suggests manual compilation. An Xcode project provides:
- Proper test target support
- Easier CI integration
- Code signing management

### Step 2: SwiftLint Configuration

Install and configure:
```bash
brew install swiftlint
```

Create `.swiftlint.yml` (adjust for this project):
```yaml
disabled_rules:
  - trailing_whitespace
opt_in_rules:
  - empty_count
included:
  - Sources
excluded:
  - build
  - .build
line_length: 120
```

### Step 3: Pre-commit Adaptation

Current `.pre-commit-config.yaml` is Python-focused. Add Swift hooks:

```yaml
# Add to existing config (keep useful general hooks):
  - repo: local
    hooks:
      - id: swiftlint
        name: SwiftLint
        entry: swiftlint lint --strict
        language: system
        files: \.swift$
        pass_filenames: false
```

### Step 4: XCTest Smoke Tests

Create test structure. If using Xcode project:
- Add test target (File > New > Target > Unit Testing Bundle)
- Create `AudioRecordingManagerTests/SmokeTests.swift`

Basic smoke test:
```swift
import XCTest

class SmokeTests: XCTestCase {
    func testProjectCompiles() {
        XCTAssertTrue(true, "Project compiles and tests run")
    }

    func testSwiftVersion() {
        #if swift(>=5.0)
        XCTAssertTrue(true)
        #else
        XCTFail("Swift 5+ required")
        #endif
    }
}
```

### Step 5: GitHub Actions CI

Create `.github/workflows/ci.yml` for **macOS** (not iOS):

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  test:
    name: Test on macOS
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
            -destination 'platform=macOS' \
            -enableCodeCoverage YES

      - name: SwiftLint
        run: |
          brew install swiftlint
          swiftlint lint --strict
```

---

## Files to Create/Modify

| File | Action | Purpose |
|------|--------|---------|
| `scripts/verify-setup.sh` | Create | Pre-flight verification |
| `AudioRecordingManager.xcodeproj/` OR `Package.swift` | Create | Project structure |
| `.swiftlint.yml` | Create | Linting configuration |
| `.pre-commit-config.yaml` | Modify | Add Swift hooks |
| `AudioRecordingManagerTests/SmokeTests.swift` | Create | Basic test suite |
| `.github/workflows/ci.yml` | Create | CI pipeline |
| `docs/TESTING.md` | Create | Testing documentation |

---

## Acceptance Criteria Checklist

### Must Have
- [ ] Pre-flight verification passes (`./scripts/verify-setup.sh`)
- [ ] Project structure created (Xcode or SPM)
- [ ] SwiftLint configured and passing
- [ ] Pre-commit hooks updated for Swift
- [ ] Smoke tests run successfully
- [ ] GitHub Actions CI workflow created
- [ ] `docs/TESTING.md` documents TDD workflow

### Should Have
- [ ] Pre-commit runs in <30 seconds
- [ ] CI workflow uses macOS destination (not iOS)
- [ ] Clear error messages in CI failures

---

## Common Pitfalls to Avoid

1. **iOS vs macOS**: Task spec mentions iOS - this is macOS. Use `platform=macOS` in xcodebuild.

2. **Existing build.sh**: Don't remove it - it's the current working build. Add Xcode project alongside.

3. **Test Target Linking**: Ensure test target can access main module.

4. **Code Signing in CI**: Use `CODE_SIGN_IDENTITY=""` and `CODE_SIGNING_REQUIRED=NO` for CI.

---

## Success Metrics

- Smoke tests run in <5 seconds
- Pre-commit hooks complete in <30 seconds
- CI workflow completes in <10 minutes
- All tests pass on macOS

---

## After Completion

1. Move task from `2-todo/` to `5-done/`
2. Update `.agent-context/agent-handoffs.json`
3. Verify CI passes on GitHub
4. Ensure subsequent tasks can follow TDD workflow
