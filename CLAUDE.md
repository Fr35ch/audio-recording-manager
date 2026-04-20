# CLAUDE.md

This file gives future Claude sessions the context they need to be useful on this project without re-deriving it each time.

## Project at a glance

**Audio Recording Manager (ARM)** — a macOS SwiftUI app for NAV (Norwegian Labour and Welfare Administration) researchers. Records user interviews, transcribes them (local NB-Whisper), optionally anonymizes and analyses, and uploads the results to Microsoft Teams/SharePoint.

- **Language/stack:** Swift 5.9+, SwiftUI, AVFoundation. Xcode project (`AudioRecordingManager.xcodeproj`) with a Swift Package manifest (`Package.swift`) for ergonomics. Python helpers for transcription / anonymization / LLM work are invoked via `Process`.
- **Target:** macOS 14 Sonoma minimum, Apple Silicon, 16 GB RAM, 30 GB disk.
- **UI language:** Norwegian (Bokmål). User-facing copy should be Norwegian unless otherwise specified.
- **Design system:** Liquid Glass (native macOS materials). See ADR-1007 (NAV Aksel was superseded). Use `AppColors`, `AppSpacing`, `AppRadius` — not NAVColors/NAVSpacing.
- **Versioning:** SemVer, tracked in `VERSION`, `Info.plist`, and `CHANGELOG.md`. Current: see `VERSION`. Release script at `scripts/release.sh`. Full guide in [docs/VERSIONING.md](docs/VERSIONING.md).

## Who the users are and why it matters

Researchers interviewing NAV service recipients and employees. Interview content is **highly sensitive personal data**. The product is installed on **researchers' own NAV-issued machines**. This drives most architectural decisions:

- Files live under `~/Library/Application Support/AudioRecordingManager/` — excluded from roaming profile sync via MDM, never on the Desktop
- Anonymization runs inside ARM (AnonymizationSectionView in the transcript editor) before upload
- Data uploads to **backup-excluded private Teams channels** per the NAV routine for temporary storage of insight data (ref. PVK 25/35628)
- Teams enforces 8-month automatic deletion; ARM surfaces this retention window prominently but does not enforce it locally
- The **Return Machine flow** lets researchers verifiably wipe all local interview data at the end of a project, producing a timestamped receipt

## Current architectural state (as of 2026-04-14)

### File storage — mid-pivot, documented in ADR-1014

**Today's code** still stores files on the Desktop at `~/Desktop/lydfiler/` (audio) and `~/Desktop/tekstfiler/` (transcripts), linked by filename stem. The audit log is a hidden dotfile inside the audio folder.

**Target (Phase 0, planned)** moves all data to `~/Library/Application Support/AudioRecordingManager/` with UUID-named per-recording folders containing audio + transcript + metadata sidecar. MDM excludes this path from roaming profile sync. Egress moves from manual-drag-into-Teams to direct Graph API upload (Phase 1). Local files are only ever deleted via an explicit Return Machine flow.

If you are asked to add features that interact with file storage, **check which world the task belongs to**:

- If the code you're touching still uses `~/Desktop/lydfiler/`, the pivot hasn't landed yet — work within the old layout and minimise new coupling so the pivot stays tractable.
- If the code is under `Sources/AudioRecordingManager/Storage/` (new), the pivot has begun — use `RecordingStore` APIs, not direct path construction.
- Do not add new code paths that write to Desktop. The Desktop is being eliminated as a storage location.

Key documents for file management:
- [ADR-1014](docs/decisions/adr/ADR-1014-file-storage-architecture-pivot.md) — the decision
- [docs/FILE_MANAGEMENT_AND_TEAMS_SYNC.md](docs/FILE_MANAGEMENT_AND_TEAMS_SYNC.md) — the spec
- [docs/prd/file-management-teams-sync/USER_STORIES.md](docs/prd/file-management-teams-sync/USER_STORIES.md) — the stories
- [docs/prd/file-management-teams-sync/PHASE_0_TASKS.md](docs/prd/file-management-teams-sync/PHASE_0_TASKS.md) — the build-order task list

## Codebase orientation

All Swift sources live under `Sources/AudioRecordingManager/`. The file `main.swift` is very large and contains much of the app; it is being incrementally broken up. Other notable files:

| File | Purpose |
|------|---------|
| `main.swift` | App entry, `AudioRecorder`, `AudioFileManager`, `RecordingsManager`, main UI views, settings, etc. (large — expect to read chunks, not whole) |
| `AudioLevelVisualization.swift` | Scrolling waveform drawn with `Canvas`. Right-anchored, buffer capped at 1000 entries (50 s at 20 Hz). Source of truth for visualization is `AVAudioRecorder` metering at 20 Hz. |
| `TranscriptionService.swift` | Invokes Python NB-Whisper bridge via `Process`. |
| `TranscriptManager.swift` | Surfaces `RecordingStore` transcripts as `[TranscriptItem]`. |
| `AnonymizationService.swift` | Invokes `no-anonymizer` Python library. |
| `AuditLogger.swift` | Append-only JSONL audit log under `~/Library/Application Support/AudioRecordingManager/audit/`. |
| `Startup/*` | Splash screen, hardware checks, dependency verification. |
| `Storage/*` | Phase 0 storage layer: `RecordingStore`, `StorageLayout`, metadata sidecars, migration from legacy Desktop folders. |
| `Design/*` | **Protected design surface** — colours, spacing, radii, button styles, window chrome reference. See `Design/README.md` before editing. |
| `RecordingDetailView.swift`, `TranscriptsView.swift`, `MainView.swift`, etc. | UI. |

## Design surface — protected boundary

`Sources/AudioRecordingManager/Design/` is the single source of truth for visual style:

- `DesignTokens.swift` — `AppColors`, `AppSpacing`, `AppRadius`
- `GlassStyles.swift` — `GlassButtonStyle`, `HoverButtonStyle`, `glassEffectIfAvailable`
- `WindowChrome.swift` — canonical window chrome shape (documentation) + `TabContentChrome` + `WindowSize`
- `README.md` — rules and rationale

**Rules for future Claude sessions:**

1. **Do not "fix" layout by editing `Design/`.** If the app looks off, the problem is almost always a callsite using the wrong token, or a tab missing a chrome hook — not a design token being wrong. Start at the callsite.
2. **Never hardcode a colour, spacing, or corner radius outside `Design/`.** Use the tokens.
3. **Never add these chrome workarounds outside `Design/`** (they historically fought the canonical chrome):
   - `.ignoresSafeArea(edges: .top)` on the main view tree
   - `Spacer().frame(height: 52)` as a manual title-bar inset
   - `.toolbarBackground(.hidden, for: .windowToolbar)`
   - `.navigationTitle("")` added solely to suppress chrome
   - Direct `NSWindow` manipulation (`titlebarAppearsTransparent`, `fullSizeContentView`, `titleVisibility`, `styleMask`) in `AppDelegate`
4. **`VirginProjectApp.body` chrome modifiers and `Design/WindowChrome.swift` must stay in sync.** The `.windowStyle()` / `.windowToolbarStyle()` modifiers must live on the `Scene` (can't be packaged into a `ViewModifier`), but `WindowChrome.swift` documents their canonical shape.
5. **If a design change is genuinely needed, ask the user first.** Don't edit `Design/` speculatively.

## External dependencies and services

- **Python 3.10+** for transcription and anonymization. Not bundled; app checks on startup (`DependencyManager`).
- **no-transcribe** (Python) — NB-Whisper wrapper for Norwegian speech-to-text.
- **no-anonymizer** (Python, `[ner]` extras) — HuggingFace BERT-based NER for anonymization. SpaCy dependency was removed in 1.4.0.
- **Ollama** — local LLM runtime for analysis. Optional.
- **DSS Player for Mac** (Olympus) — for decrypting DS2 files. License-blocked; see BACKLOG.md.
- **Microsoft Graph (Entra ID)** — planned for Phase 1 upload. Requires Azure AD app registration in NAV tenant.

## Conventions

- **File references in Markdown:** use `[filename.swift:line](path)` format for IDE clickability — the VS Code extension context requires it.
- **Norwegian in UI, English in code and comments.** Exception: phrases the user types verbatim (e.g., `SLETT ALLE FILER` friction gate).
- **ADRs** go under `docs/decisions/adr/` using the template at `docs/decisions/adr/TEMPLATE-FOR-ADR-FILES.md`. Use the next available `ADR-1xxx` number.
- **PRDs / user stories** go under `docs/prd/<epic-name>/USER_STORIES.md`. One epic per folder.
- **Never write to the Desktop from new code.** Existing Desktop writes are being removed, not augmented.
- **Bus-factor documents** (ADRs, PRDs, CHANGELOG) are how this project preserves context across sessions — if you make a meaningful decision during work, record it where it belongs rather than burying it in a commit message.

## Recurring themes the project is sensitive to

1. **Compliance, not polish.** This app handles personal data belonging to vulnerable people. Correctness and auditability beat cleverness and features.
2. **The 8-month Teams retention is not decorative.** Files on the backup-excluded private channels are auto-deleted by M365 after 8 months with no recovery path. Do not design features that assume data lives indefinitely on Teams. ARM must surface this retention window clearly.
3. **The Return Machine flow is a researcher-initiated data hygiene step.** It lets researchers verifiably wipe all local interview data at end-of-project. Wipe is auditable by design (receipt file + final audit log). It is not a machine-handoff or library-return contract.
4. **Anonymization is optional but in-scope.** It runs inside ARM via AnonymizationSectionView (transcript editor) before upload. Never make anonymization status a blocker for upload or Return Machine — it is the researcher's responsibility, not a gate ARM enforces.
5. **Researcher interviews haven't happened yet.** Some UX decisions are deliberately deferred until the product owner completes discovery. Check whether a task you're given depends on those answers; if so, flag it rather than inventing a design.

## When in doubt

- Read the most recent ADR first — decisions are durable there.
- Read `CHANGELOG.md` for the last one or two minor versions to see what's just changed.
- Read the Phase 0 task list if touching storage or upload — those are the live workstreams.
- Ask the user to clarify scope before starting large edits. Many tasks in this codebase have subtle compliance implications that aren't obvious from the code alone.

## Key decisions log (pointer index)

- ADR-1007: NAV Design System integration (historical — superseded by Liquid Glass migration in 1.4.0)
- ADR-1014: File storage architecture pivot (this is the big one — read it)

*ADR-1006 (network isolation / zero-trust stance) is superseded. ARM is installed on researchers' own NAV-issued machines; ARM no longer manages network state.*

## Build & run

- Xcode: `⌘B` to build, `⌘R` to run. Minimum macOS 14.
- Release script: `./scripts/release.sh <patch|minor|major>` — see [docs/VERSIONING.md](docs/VERSIONING.md).
- Python dependencies are user-installed; `DependencyManager` verifies on launch.
