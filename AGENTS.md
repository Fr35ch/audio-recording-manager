# AGENTS.md

This file is read automatically by AI coding agents at the start of every session. Its purpose is to establish shared context, prevent recurring mistakes, and enforce project conventions.

---

## 1. Project overview

Clio is a macOS SwiftUI app for NAV (Norwegian Labour and Welfare Administration) researchers. It records user interviews, transcribes them locally using NB-Whisper, supports transcript editing and de-identification, and uploads results to Microsoft Teams/SharePoint via Graph API. It is installed on researcher-issued NAV machines and handles highly sensitive personal data from interviews with NAV service recipients and employees.

---

## 2. Architecture overview

### App entry point
`ClioApp` (`@main`, `Sources/Clio/main.swift:18`) uses `@NSApplicationDelegateAdaptor(AppDelegate.self)`. On launch, `AppDelegate.applicationDidFinishLaunching` hides the main window, runs `StartupCoordinator.runStartupSequence()` (hardware and dependency checks), and then shows `MainView`. A secondary `WindowGroup(id: "transcript-editor", for: UUID.self)` hosts per-recording `TranscriptEditorWindow` scenes.

### Source layout
All Swift lives under `Sources/Clio/`:

| Directory / File | Role |
|---|---|
| `main.swift` | `ClioApp`, `AppDelegate`, `MainView`, `AudioRecorder` – still large, being incrementally split |
| `AudioRecorder.swift` | `AVAudioRecorder` + `AVAudioEngine` tap, FFT-based VAD (Accelerate, 300–3400 Hz), adaptive noise floor |
| `AudioLevelVisualization.swift` | Right-anchored `Canvas` waveform, 1000-sample buffer, 20 Hz metering |
| `TranscriptionService.swift` | Subprocess bridge to `no-transcribe` Python CLI |
| `AnonymizationService.swift` | Subprocess bridge to `no-anonymizer` Python CLI |
| `AuditLogger.swift` | Append-only JSONL audit log; monthly rotation |
| `FluidDiarizationService.swift` | CoreML on-device speaker diarization (FluidAudio SDK; replaced pyannote subprocess) |
| `OllamaManager.swift` | Manages Ollama subprocess lifecycle + health check at `localhost:11434` |
| `Design/` | **Protected design surface** — see §3 and §7 |
| `Startup/` | Splash, `DependencyManager`, `SystemRequirementChecker`, `StartupCoordinator` |
| `Storage/` | Phase 0 storage layer: `RecordingStore`, `StorageLayout`, `RecordingMeta`, `RecordingExpiryManager` |
| `Upload/` | Graph API upload layer (Phase 1, partially stubbed): `TeamsUploadService`, `UploadGate` |

### Python subprocess bridges
All Python invocations use `Foundation.Process`. Pattern: stderr parsed live via `readabilityHandler` for progress/stage updates; stdout read after exit for final JSON result.

| Service | Invocation | Output |
|---|---|---|
| Transcription | `python3 -m no_transcribe --audio <path> --model large ...` | JSON: `segments [{speaker, start, end, text}]` |
| Anonymization | `python3 -m no_anonymizer.cli --text <transcript> --language no` | JSON: `anonymizedText`, `redactions [{position, length, category, replacement}]` |
| Ollama | `ollama serve` (subprocess managed by `OllamaManager`; binary found in `/opt/homebrew/bin/`, `/usr/local/bin/`) | HTTP API at `localhost:11434` |

### External dependencies
- **Python 3.10+** — not bundled; verified on launch by `DependencyManager`
- **no-transcribe** — NB-Whisper wrapper for Norwegian speech-to-text
- **no-anonymizer** — HuggingFace BERT-based NER; SpaCy dependency removed in 1.4.0
- **FluidAudio** — CoreML speaker diarization SDK (`Package.swift` dependency, `from: "0.12.4"`)
- **Ollama** — local LLM runtime, optional
- **Microsoft Graph (Entra ID)** — Phase 1 upload; requires Azure AD registration with `Files.ReadWrite`, `Sites.ReadWrite.All`, `User.Read` scopes

### File storage
All storage uses the Phase 0 layout under `~/Library/Application Support/Clio/`. Desktop storage (`~/Desktop/lydfiler/`, `~/Desktop/tekstfiler/`) has been removed from the live codebase — references remain only in `LegacyStorageScanner` (migration) and comments. See ADR-1014.

```
recordings/<uuid>/
    audio.m4a
    transcript.txt
    meta.json          ← source of truth; never parse filenames
audit/
    audit-YYYY-MM.jsonl
state/
    app.json
```
All path construction goes through `StorageLayout` (enum, `Sources/Clio/Storage/StorageLayout.swift`). CRUD goes through `RecordingStore`. Do not bypass either.

**Remaining Phase 0 work (see `docs/prd/file-management-teams-sync/PHASE_0_TASKS.md`):**
- D2: `TranscriptionService` not yet writing to the recording folder — still uses a legacy `AudioRecordingManager/transcripts/` path
- D5/D6: Some `URL(fileURLWithPath: recording.path)` sites and `AudioFileManager` class still exist in `main.swift`
- E1–E3: Desktop-egress UI actions not yet removed
- 0F: 30-day expiry implemented but disabled pending migration strategy

---

## 3. Established patterns

### Design tokens
All colors, spacing, and radii are defined in `Sources/Clio/Design/DesignTokens.swift` as `AppColors`, `AppSpacing`, `AppRadius`, `AppSize`. Never hardcode these values elsewhere. The `Design/` folder is a protected boundary — see §7.

### Glass button styles
Use `GlassButtonStyle` (primary) and `HoverButtonStyle` (secondary) from `Sources/Clio/Design/GlassStyles.swift`. Both include compile-time availability fallback for pre-macOS 26 via `glassEffectIfAvailable(in:)`.

### State management
- `@StateObject` for view-local lifecycle objects
- `@Published` + `ObservableObject` for services shared across views (e.g., `TranscriptionService`, `StartupCoordinator`)
- `@ObservedObject` for shared singletons (e.g., `AudioRecorder.shared`, `OllamaManager.shared`)
- `@AppStorage` for simple UserDefaults-backed settings
- `NotificationCenter` for cross-window events (e.g., `"ClioShowLogViewer"`, `RecordingStore.didChangeNotification`)
- `@MainActor` on `AppDelegate` and `StartupCoordinator`; background work marshalled back to main thread

### Settings
Registered in `AppDelegate.applicationDidFinishLaunching` via `UserDefaults.standard.register(defaults:)`. Keys are namespaced (e.g., `"transcription.defaultModel"`, `"transcription.language"`). Access from SwiftUI via `@AppStorage("key")`.

### Error handling
Domain error enums with `LocalizedError` conformance: `TranscriptionError`, `RecordingStoreError`. All subprocess errors capture `terminationStatus` + stderr. Failures are audit-logged (never logging free-form user text — counts and identifiers only).

### Audit logging
`AuditLogger` writes append-only JSONL to `~/Library/Application Support/Clio/audit/audit-YYYY-MM.jsonl`. Schema: `{timestamp, actor, host, eventType, payload: [String: AuditValue]}`. `AuditValue` is a heterogeneous enum for forward compatibility. Writes are atomic (temp-file + rename).

### Metadata serialization
Per-recording metadata updates in `RecordingStore` are serialized via a per-recording `DispatchQueue` to prevent races between concurrent recorder and transcriber writes.

---

## 4. Compliance constraints

This app handles highly sensitive personal data. These constraints are non-negotiable:

- **Never write to the Desktop from new code.** Existing Desktop paths are being removed, not augmented.
- **All new storage goes through `RecordingStore` and `StorageLayout`.** No direct path string construction.
- **Anonymization is optional, not a gate.** Never block upload on anonymization status — it is the researcher's responsibility.
- **Local recordings auto-delete 30 days after creation** (with warnings at day 23 and day 29). Do not design features that assume local files persist indefinitely.
- **Teams/SharePoint enforces 8-month deletion** with no recovery path. Do not design features that assume data persists on Teams.
- **Audit log is append-only and tamper-evident.** Do not make it user-editable. Never log free-form interview content.
- **Files must be excluded from roaming profile sync.** `~/Library/Application Support/Clio/` relies on MDM configuration. If this fails, ADR-1014 must be revisited.
- **UI language is Norwegian (Bokmål).** All user-facing copy must be Norwegian unless explicitly discussed otherwise.

---

## 5. Agent roles

Agents are defined in `.claude/agents/`. Invoke them via `/agent-name` or the Task tool.

| Agent | Scope | Model tier |
|---|---|---|
| `tycho` | Everyday task coordination, status tracking, facilitates evaluation workflows | Sonnet |
| `planner` | Work planning, task decomposition, cross-agent coordination, ADR/PRD drafting | Opus |
| `feature-developer` | Feature implementation to spec | Opus |
| `security-reviewer` | Security analysis and hardening; read-only investigation | Opus |
| `test-runner` | Run test suites, verify implementations, report pass/fail | Sonnet |
| `powertest-runner` | Comprehensive TDD, test strategy, coverage analysis | Sonnet |
| `document-reviewer` | Documentation quality and completeness review | Sonnet |
| `ci-checker` | GitHub Actions workflow status after push; minimal scope | Haiku |
| `agent-creator` | Guide creation of new specialized agents with standardized frontmatter | Sonnet |
| `onboarding` | First-run project configuration for new agentive projects | Sonnet |

Model tiers: Opus → premium (complex reasoning); Sonnet → standard; Haiku → fast/cheap (status checks).

---

## 6. Build and run

**Build (Xcode — preferred):**
```
⌘B in Xcode (Clio.xcodeproj)
```

**Build (CLI — for CI or headless):**
```bash
swift build
```

**Run:**
```
⌘R in Xcode
```
Requires macOS 14+ and Apple Silicon. Python dependencies must be installed separately; `DependencyManager` verifies on launch.

**Release:**
```bash
./scripts/release.sh <patch|minor|major>
```
Updates `VERSION`, `Info.plist`, `CHANGELOG.md`. Full guide in `docs/VERSIONING.md`.

**Python tests:**
```bash
pytest -m "not slow"          # fast tests (pre-commit default)
pytest                        # all tests
```

**Linting:**
```bash
swiftlint lint --quiet        # Swift (pre-commit hook; optional if not installed)
pre-commit run --all-files    # all hooks (black, isort, flake8, swiftlint)
```

**Pre-commit (auto-runs on `git commit`):**
Hooks: trailing-whitespace, check-yaml, black (88-char), isort, flake8 (critical errors only), swiftlint, pytest fast tests. Skip with `SKIP_TESTS=1` or `SKIP_SWIFT_BUILD=1`.

---

## 7. Deliberate decisions — do not change

### Design surface is a protected boundary
`Sources/Clio/Design/` is the single source of truth for visual style. Rules enforced by `Design/README.md`:

1. **Do not edit `Design/` to fix layout.** The problem is almost always a callsite using the wrong token. Fix the callsite.
2. **Never hardcode color, spacing, or corner radius outside `Design/`.** Use `AppColors`, `AppSpacing`, `AppRadius`.
3. **Never add these patterns outside `Design/`:**
   - `.ignoresSafeArea(edges: .top)` on the main view tree
   - `Spacer().frame(height: 52)` as a manual title-bar inset
   - `.toolbarBackground(.hidden, for: .windowToolbar)`
   - `.navigationTitle("")` added solely to suppress chrome
   - Direct `NSWindow` property manipulation: `titlebarAppearsTransparent`, `fullSizeContentView`, `titleVisibility`, `styleMask`
4. **`ClioApp.body` chrome modifiers and `Design/WindowChrome.swift` must stay in sync.** The `.windowStyle(.hiddenTitleBar)` and `.windowToolbarStyle(.unified(showsTitle: false))` modifiers must live on the `Scene` — they cannot be packaged into a `ViewModifier`.

### File storage pivot (ADR-1014)
- **Do not add new Desktop write paths.** The Desktop storage layout is being eliminated.
- **`StorageLayout` is the only place path strings are constructed.** All callers must use its APIs.
- **The MDM sync exclusion is load-bearing.** If `~/Library/Application Support/Clio/` is not excluded from roaming sync, researcher data would appear on all NAV machines. If MDM exclusion fails, this ADR must be revisited — do not work around it.

### 30-day retention is not yet enforced
Auto-deletion is implemented in `RecordingExpiryManager` but intentionally disabled pending a grace-period migration (it would retroactively delete recordings created before the policy). Do not re-enable it without a migration strategy.

### Anonymization is not a gate
Upload must never be blocked by anonymization status. This is a deliberate compliance decision: it is the researcher's legal responsibility, not an application-level enforcement.

### NAV design system (superseded)
`NAVColors`, `NAVSpacing`, `NAVRadius` no longer exist. The migration to Liquid Glass (`AppColors` etc.) was completed in v1.4.0. Do not re-introduce NAV Aksel tokens.

### `StorageLayout` avoids Desktop paths deliberately
`Sources/Clio/Storage/StorageLayout.swift` contains no Desktop path references. This is intentional. Do not add any.


---

## 8. Documentation index

All project documentation is indexed in [`docs/README.md`](docs/README.md). That file lists every doc, its purpose, and when it was last verified against the codebase.

**Before editing any doc:** check `docs/README.md` to understand its scope.
**After making architectural changes:** update the relevant doc and bump its verification date in `docs/README.md`.
**For staleness checks:** run the `document-reviewer` agent (`/document-reviewer`).
