# Changelog

All notable changes to Clio will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.5.0-beta.1] - 2026-05-27

### Added — Borealis beta
- **Borealis språkmodell-støtte** — Nav-innsiktsmedarbeidere kan nå prøve Borealis 4B og 12B fra Nasjonalbiblioteket som LLM-motor for analyse og avidentifisering. Borealis er spesielt trent for norsk bokmål.
- **Beta-tilgang i innstillinger** — Ny seksjon «Språkmodell for analyse» med toggle for beta-tilgang. Borealis-modeller vises kun når beta er aktivert.
- **Automatisk modell-nedlasting ved oppstart** — Hvis Borealis er valgt og ikke lastet ned, hentes modellen automatisk via `ollama pull` ved oppstart med fremdriftslinje.
- **Modellkatalog** (`LLMModel`) — Strukturert oversikt over støttede LLM-modeller med RAM-krav, beskrivelse og beta-flagg.
- **In-app modell-nedlasting** — «Hent modell»-knapp i innstillinger for å laste ned Borealis uten å forlate appen.

### Changed
- Innstillingsvinduet er nå scrollbart og har fått minimum høyde 500 px for å romme ny LLM-seksjon.
- `DependencyManager` leser nå valgt LLM-modell fra UserDefaults istedenfor hardkodet `qwen3:8b`.

## [Unreleased]

Architectural redesign of file storage, egress, and machine handoff. Decision captured in [ADR-1014](docs/decisions/adr/ADR-1014-file-storage-architecture-pivot.md); spec revised in [docs/FILE_MANAGEMENT_AND_TEAMS_SYNC.md](docs/FILE_MANAGEMENT_AND_TEAMS_SYNC.md); build order in [docs/prd/file-management-teams-sync/PHASE_0_TASKS.md](docs/prd/file-management-teams-sync/PHASE_0_TASKS.md). Intended for the next major release (2.0.0) because it changes storage location and removes Desktop-write paths.

### Fixed — Literal `<|nocaptions|>` shown as real transcript text on whisper.cpp output

User reported a short 15-second test recording transcribed to a single
segment reading literally `<|nocaptions|>` — a known NB-Whisper training-data
hallucination artifact, not a real special/control token, that
`NativeTranscriptionEngine.sanitize` has always stripped. Root cause: when
`WhisperCppEngine` was written during this session's engine pivot, its own
`sanitize()` only carried over the empty-text and letter-free checks —
the hallucination-marker stripping was dropped entirely. `<|nocaptions|>`
contains real letters ("nocaptions"), so it passed straight through both
remaining checks and was shown to the researcher as if it were genuine
transcript content.

- `WhisperCppEngine.sanitize` now strips the same
  `NativeTranscriptionEngine.knownHallucinationMarkers` list (made
  non-private so both engines can share it — this is a property of the
  NB-Whisper model's own training data, not either specific runtime, so
  both need the identical marker list) before the empty/letter-free
  checks, exactly matching `NativeTranscriptionEngine`'s original
  behavior.
- Real, complete `xcodebuild` — `** BUILD SUCCEEDED **`.
- Note for the user: this only fixes *future* transcriptions — the
  specific recording in the report already has this bad text saved to
  disk and needs to be re-transcribed (now safe to do, given the earlier
  cancel/re-transcribe fix this session) to pick up the fix.

### Fixed — "Godkjenn og signer" appeared to do nothing in the transcript editor until closing and reopening

User: pressing the sign-off button in the transcript editor didn't
visibly confirm anything, but closing the editor showed it as approved
after all. Traced to a real race between two pieces of code, both
individually reasonable, that combined into a bug:

- `TranscriptEditorView.loadExistingState()` only ever read
  `anonymization.researcherConfirmedAt` from inside its `status == .done`
  branch — but `AnonymizationConfirmationService.confirm` (the manual
  "confirm without running the automatic tool" path added earlier this
  session) deliberately never sets `status` to `.done`, only
  `researcherConfirmedAt` itself. So this method could never observe a
  manual-only confirmation at all.
- `RecordingStore.notifyDidChange` posts its `didChangeNotification` via
  `DispatchQueue.main.async` — deferred to the next run-loop tick, not
  synchronous. `TranscriptEditorView` listens for that notification and
  calls `loadExistingState()` in response (so the editor picks up
  external sidecar changes while open). Since `confirmSignOff()`'s own
  `researcherConfirmedAt = updated.anonymization.researcherConfirmedAt`
  happened *before* the deferred notification fired, the
  notification-triggered reload ran right after and — hitting the gate
  above — silently clobbered the just-set correct value back to `nil`.
  The Library view's own confirmation section was unaffected (it reads
  `researcherConfirmedAt` directly, with no such gate), which is why
  closing the editor and looking at the recording list showed the
  correct, already-confirmed state.
- Fixed by reading `researcherConfirmedAt` unconditionally whenever the
  sidecar loads — confirmation is orthogonal to whether the automatic
  anonymizer ran, which is exactly how the Library view already treated
  it; only the anonymization-stats display genuinely depends on
  `status == .done`.
- Real, complete `xcodebuild` — `** BUILD SUCCEEDED **`.

### Fixed — Cancelling a transcription never actually stopped it, permanently blocking re-transcription ("en transkripsjon kjører allerede")

User reported two symptoms that turned out to share one root cause:
cancelling a transcription still showed "en transkripsjon kjører
allerede" indefinitely, and re-transcribing any file (not just the
cancelled one) was blocked the same way — both gated by the same global
`TranscriptionService.isBusy` flag.

Root cause: `TranscriptionService.cancel()` only reset UI state
(`progress`/`stage`) — it never actually stopped the in-progress
`WhisperCppEngine` decode. Swift's `Task.cancel()` (called by
`TranscriptionRunner.cancel`) cannot interrupt `whisper_full()`, a single
long synchronous C call with no cooperative cancellation checks. The real
decode kept running to completion in the background — for a real
interview, several minutes — holding `isBusy == true` the entire time and
blocking every subsequent "Transkriber"/"Transkriber igjen" click network-wide, no matter which
recording.

- New `WhisperCppEngine.CancellationToken` — a plain, lock-protected,
  non-actor-isolated flag (deliberately NOT actor state: a "Cancel" button
  on the main actor must be able to flip it instantly, without waiting on
  `WhisperCppEngine`'s serial executor, which is exactly what's busy for
  the whole decode).
- Wired into whisper.cpp's own real, built-for-this-purpose
  `whisper_full_params.abort_callback` mechanism (confirmed directly in
  the whisper.cpp source: `whisper_encode_internal`/
  `whisper_decode_internal` check it between compute steps and cause
  `whisper_full` to return a distinct negative code — `-6`, `-8`, or `-9`
  depending on which of the three call sites aborted — the moment it's
  set, rather than continuing).
- `TranscriptionService` creates a fresh token at the start of every
  `transcribe(...)` call, threads it through all three
  `WhisperCppEngine.shared.transcribe(...)` call sites (main pass,
  per-channel stereo pass, escalating-temperature repair — the last of
  which also now bails out of its small bounded retry loop the moment
  cancellation is requested, instead of burning several more near-instant
  aborted attempts), and `cancel()` now calls `token.cancel()` directly.
- **Verified with a real, direct reproduction against the actual
  production model and an actual ~35-minute interview recording**: a
  standalone test cancelled 1.5 seconds after starting a real beam-search-5
  decode — `whisper_full` returned in **1.58 seconds total** (not the
  several minutes a full decode of that file takes), confirming the abort
  is genuinely prompt, not just theoretically wired up.
- Real, complete `xcodebuild` — `** BUILD SUCCEEDED **`.

### Fixed — Real compliance bug: re-running auto-anonymize left a stale researcher confirmation in place, silently skipping required sign-off

User reported: running the automatic anonymizer no longer required the
mandatory manual "this is truly anonymized" confirmation step afterward.
Root cause confirmed by reading both anonymization entry points
(`TranscriptEditorView.runAnonymization`, `AvidentifiseringSheet
.runAnonymization`): neither ever cleared
`anonymization.researcherConfirmedAt` when a fresh run completed. If a
recording had *any* prior confirmation — from an earlier confirm, or from
re-running the tool (e.g. via the editor's "Kjør avidentifisering på
nytt" button) — that old timestamp stayed in place even though the
anonymized text had just been regenerated and never reviewed by the
researcher in its new form. The UI then showed the recording as already
confirmed/ready to download, silently skipping the compliance-critical
manual review step.

- Both `runAnonymization()` implementations now explicitly reset
  `anonymization.researcherConfirmedAt = nil` (and the editor's own local
  `researcherConfirmedAt` state) whenever a fresh anonymization run
  completes, so the sign-off bar demands a new "Godkjenn og signer" click
  every time the anonymized content changes — never carries over a stale
  confirmation for content the researcher hasn't actually reviewed.
- Logs `AuditLogger.logAnonymizationConfirmationRevoked` when a prior
  confirmation is invalidated this way (only when one actually existed,
  to avoid spurious audit noise on first-ever runs), giving the same
  audit trail an explicit manual revoke already produces.
- **Confirmed the second, related requirement already works as intended**:
  a researcher can confirm de-identification *without* ever running the
  automatic tool at all — both `AvidentifiseringBekreftSection` (Library
  detail panel) and the transcript editor's sign-off bar are shown
  regardless of whether the automatic tool ran, and
  `AnonymizationConfirmationService.confirm` explicitly supports this by
  copying the current transcript verbatim into
  `transcript_anonymized.txt` when the tool hasn't produced one.
- Real, complete `xcodebuild` — `** BUILD SUCCEEDED **`.

### Fixed — App crashed/save panel silently failed to appear on "Last ned som TXT"/"Last ned som RTF"

User tried the newly-restored download feature and hit a crash. The real
debug log showed the actual cause at the very end: *"Unable to display
save panel: your app is missing the User Selected File Read/Write app
sandbox entitlement."* Confirmed directly: `Clio.xcodeproj` has
`ENABLE_APP_SANDBOX = YES` but never had
`com.apple.security.files.user-selected.read-write` granted — none of
Xcode's newer `ENABLE_*` sandbox-capability build settings for file access
were present at all (only audio input, Bluetooth, and a handful of
resource-access toggles). `NSSavePanel` cannot present at all without this
entitlement in a sandboxed app.

- Added `ENABLE_USER_SELECTED_FILES = readwrite;` to both Debug and Release
  target configs in `Clio.xcodeproj/project.pbxproj` — the actual
  Xcode-recognized build setting name/value for this capability (this
  exact fix and setting name was previously found and verified on the
  `feature/teams-upload-graph-api` branch this session's download feature
  was ported from, but the build-setting change itself hadn't been ported
  yet — this closes that gap).
- **Verified directly on the compiled binary**, not just via build success:
  `codesign -d --entitlements -` on the built `Clio.app` now shows
  `com.apple.security.files.user-selected.read-write = true` alongside the
  existing sandbox/audio/Bluetooth/network entitlements.
- Real, complete `xcodebuild` — `** BUILD SUCCEEDED **`.

### Changed — Paused Teams upload, restored local anonymized-transcript download (TXT/RTF)

User reported the Teams upload section had reappeared in the recording
detail panel while the local-download fallback (added in an earlier,
separate worktree on `feature/teams-upload-graph-api` that was never
merged back — confirmed via git history, the current branch forked before
that work landed) had gone missing, since Teams/Graph API sign-in isn't
working reliably yet. Ported the real, already-built download feature from
that branch rather than reimplementing from scratch, verified every
dependency existed or was added, and rebuilt with a full `xcodebuild`.

- **New `TranscriptDownloadSection`** replaces `TeamsUploadSection` in the
  recording detail panel ("Last ned transkripsjon", was "Opplasting til
  Teams"). Same `UploadGate` precondition (transcript exists + researcher
  confirmed de-identification) — once ready, offers "Last ned som TXT" and
  "Last ned som RTF" buttons instead of an upload button, with an explicit
  note that Teams upload is temporarily unavailable and the file must be
  uploaded manually.
- **New `TranscriptDownloadService`** — TXT export is the anonymized
  transcript with per-line `[timestamp] Speaker: text` annotations
  (recovered by re-splitting the anonymizer's paragraph-joined output
  against the saved segment list); RTF export delegates to `RTFExporter`
  with a redaction-stats line and confirmation-date subtitle. RTF is
  Word-compatible (opens/saves as `.docx` in Word) — there is no literal
  `.docx` writer in this codebase, RTF has always been the "Word format"
  option.
- **Fixed `RTFExporter.save`** to take a completion callback instead of
  returning synchronously, deferred one run-loop tick via
  `DispatchQueue.main.async` — calling `NSSavePanel.runModal()` directly
  inside a SwiftUI `Button` action short-circuits the modal session (the
  panel never appears, `runModal()` returns `.cancel` immediately). Same
  fix applied to the new `TranscriptDownloadService.saveTXT`.
- **New `AnonymizationConfirmationService`** — single source of truth for
  what confirming de-identification does, used by both
  `AvidentifiseringBekreftSection` and `TranscriptEditorView`'s sign-off
  bar. Fixes a real gap: confirming without running the automatic
  anonymizer tool first left no `transcript_anonymized.txt` on disk at
  all, so the download feature failed with "Fant ikke den avidentifiserte
  transkripsjonen på disk" even though `UploadGate` reported ready. Now
  always produces that file — copying the current `transcript.txt`
  verbatim when the automatic tool hasn't run (the researcher confirming
  is asserting the current text, however produced, is already
  de-identified), leaving a genuine automatic-anonymization result
  untouched otherwise.
- **`TranscriptEditorView`'s sign-off bar is no longer hidden** until the
  in-editor anonymization tool completes — it's now always visible, with
  copy that adapts depending on whether the automatic tool ran
  ("Gjennomgå den avidentifiserte teksten…") or not ("Avidentifiser
  transkripsjonen med Clio-verktøyet eller manuelt…"), so a researcher who
  de-identifies manually or via an external tool can still sign off and
  unlock downloading.
- Deduplicated `TranscriptionSegment.formatTimestamp`/`.shortSpeakerLabel`
  and `AnonymizationMeta.statsSummary` out of per-file private copies
  (`TranscriptEditorView`, `AvidentifiseringSheet`) into shared static
  helpers on the model types, so the editor's inline display and every
  export format read timestamps/speaker labels/stats identically.
- `TeamsUploadSection`/`TeamsUploadService` and the rest of the Teams
  upload code are left in the tree, just no longer shown — this is a
  pause, not a removal, so re-enabling it later (once Graph API sign-in is
  reliable) is a one-line change back in `LibraryScreen.swift`.
- **Verified with a real, complete `xcodebuild` build** — `**
  BUILD SUCCEEDED **`, confirming all ported code and its dependencies
  (`UploadGate`, `AuditLogger.logTranscriptExported`, `RecordingStore`,
  `PillButtonStyle`) are compatible with this branch's current state,
  which had diverged significantly (whisper.cpp pivot, app lock, etc.)
  from the branch this feature was ported from.

- **Storage moves off the Desktop.** Audio, transcripts, and audit log relocate to `~/Library/Application Support/Clio/`. MDM-excluded from the roaming profile sync so files stay local to the library machine.
- **UUID-named recording folders** replace the filename-stem coupling between audio and transcript. Metadata moves into a per-recording `meta.json` sidecar with explicit state fields.
- **Audit log relocated** from the hidden dotfile `.audit_log.jsonl` inside the audio folder to the new data root with monthly rotation.
- **Return Machine flow** introduced as the only path that deletes local data. Pre-check, friction gate (typed phrase), zero-overwrite secure delete, receipt written to `~/Documents/` as external audit trail.
- **Manual Desktop-drag upload flow retired.** Replaced (Phase 1) by direct Microsoft Graph API upload to a per-project Teams/SharePoint destination, automatic per-artifact as each artifact reaches a stable final state.
- **Anonymization gate removed from pre-upload path.** Anonymization is a post-upload workflow on OneDrive (NAV's 30-day retention window is designed around this). ARM does not block upload on anonymization state.
- **Migration on first launch** moves any existing `~/Desktop/lydfiler/` and `~/Desktop/tekstfiler/` content into the new layout, audited.

### Documentation

- **New**: [ADR-1014](docs/decisions/adr/ADR-1014-file-storage-architecture-pivot.md) — file storage architecture pivot.
- **New**: [CLAUDE.md](CLAUDE.md) — project context for future Claude sessions.
- **New**: [docs/prd/file-management-teams-sync/PHASE_0_TASKS.md](docs/prd/file-management-teams-sync/PHASE_0_TASKS.md) — concrete build-order task list for the pivot.
- **Revised**: [docs/FILE_MANAGEMENT_AND_TEAMS_SYNC.md](docs/FILE_MANAGEMENT_AND_TEAMS_SYNC.md) — spec rewritten to reflect new architecture; the earlier Desktop + folder-picker draft is superseded.
- **Revised**: [docs/prd/file-management-teams-sync/USER_STORIES.md](docs/prd/file-management-teams-sync/USER_STORIES.md) — stories renumbered (US-FM-01 … US-FM-14). Prior US-1 … US-7 are preserved at the foot of the document as superseded, for commit-history readability.

### External dependencies kicked off (not yet confirmed)

- Azure AD / Entra ID app registration with Graph scopes `Files.ReadWrite`, `Sites.ReadWrite.All`, `User.Read` — long lead time, blocks Phase 1.
- MDM sync exclusion for `~/Library/Application Support/Clio/` — load-bearing assumption for Phase 0 security posture.
- FileVault mandate on library machines — confirmed required; awaiting IT policy confirmation.

### Added — App lock (Touch ID + password fallback)

Decision captured in [ADR-1015](docs/decisions/adr/ADR-1015-app-lock-and-file-encryption-assessment.md).

- **Mandatory app lock**, always on. The app starts locked on every launch, locks after 5 minutes of inactivity (detected both while backgrounded and while left focused but untouched), and locks immediately on system sleep or screen lock. Never locks while a recording, playback, or transcription is actively in progress.
- **Unlock via `LAContext.deviceOwnerAuthentication`** — Touch ID with automatic password fallback; no custom password screen. Degrades correctly on Macs without Touch ID.
- **Lock screen hides window content** from Cmd+Tab, Mission Control, and screen recording (`NSWindow.sharingType`) while locked; secondary transcript-editor windows are hidden entirely and restored on unlock.
- **Manual lock command** ("Lås appen nå", ⌘⌃L) for researchers who want to lock before stepping away.
- **Assessed and rejected app-managed file encryption** for `audio.m4a`/`transcript.txt` — FileVault + the existing sandbox container isolation already cover the threat model; see ADR-1015 for the full reasoning.

### Attempted and reverted

- **Stereo diarization duplicate lines / transcription precision.** Investigated a real user report of duplicate diarization lines and degraded precision since the WhisperKit port, and identified two plausible causes: (1) WhisperKit's default `chunkingStrategy` (`nil`) relies on its own loose internal seek-based segmentation rather than VAD pre-chunking, which could widen segment boundaries enough to defeat `StereoSplitter`'s cross-talk dominance filter; (2) the "Transkripsjonsnøyaktighet" (`numBeams`) setting was read from `UserDefaults` and recorded to `RecordingMeta` for display but never actually passed into a WhisperKit decode option, so it silently had no effect. Implemented fixes for both (enabling `chunkingStrategy = .vad`, and mapping `numBeams` to `DecodingOptions.temperatureFallbackCount`), verified only at the type level (no CoreML runtime available in the development environment to test against real audio). **Real-world testing showed both changes made things measurably worse** — diarization got worse and transcriptions started skipping large audio chunks, a classic symptom of VAD misclassifying genuine (if quiet or cross-talk-laden) speech as silence. Reverted both changes back to the last known-shipped state (commit `9e25be9`) rather than layer further unverified guesses on top of a regression. The original duplicate-lines/precision reports remain open and need investigation on a machine that can actually run the CoreML pipeline against real stereo audio.

### Fixed — Transcription quality regression since the WhisperKit port

Root-caused against the actual old Python pipeline this time: cloned `no-transcribe` (the `navt.py` script Clio's Python subprocess bridge used to invoke) and read its real decode parameters and code comments, rather than guessing. Two concrete, well-evidenced findings, both fixed in `NativeTranscriptionEngine.swift`:

- **Word-level timestamps were silently corrupting segment boundaries.** `navt.py`'s own comments record that HuggingFace's word-level timestamp extraction is "very experimental" and caused hallucinated filler words ("Ok.", "Så") spanning 5-22s at chunk boundaries — the old pipeline deliberately used sentence-level timestamps only, and `navt.py` in fact *never* populated word-level data at all (confirmed: `TranscriptEditorView.swift` already had a comment noting "navt.py outputs words: []"). WhisperKit's `wordTimestamps` option is architecturally different (DTW-style alignment) but has an equally serious side effect: per WhisperKit's own `TranscribeTask.swift`, when it's enabled, the seek position for the *next* decode window is recomputed from the last aligned word's end time instead of the raw segment timestamp — so alignment error on noisy/cross-talk audio (exactly the two-transmitter RØDE setup) can shift where the next window starts, skipping or duplicating audio. This matches the reported symptoms exactly. **Fixed by turning `wordTimestamps` off**, restoring exact behavioral parity with the old pipeline (`segment.words` is always empty, which the transcript editor already renders correctly — the word-level karaoke UI was speculative future-facing code that was never actually exercised before the WhisperKit port).
- **`<no captions>` placeholder text leaking into transcripts.** The existing hallucination-marker filter only matched the literal string `"<|nocaptions|>"` (Whisper's internal special-token syntax), but the bundled CoreML model emits this placeholder in other forms too (observed: `<no captions>`, without pipes). Expanded the marker list to cover the observed variants and other bracket styles, and made matching case-insensitive.

Both changes verified via `swiftc -typecheck` against the real, previously-built `WhisperKit.swiftmodule`/`yyjson` artifacts in Xcode's DerivedData (not hand-written stubs) — zero errors/warnings. As with the reverted attempts above, this environment has no CoreML runtime to confirm against real audio; needs testing on real RØDE stereo recordings. Unlike the reverted attempts, both fixes are backed by direct evidence from the actual reference implementation and WhisperKit's own source, not speculation about a hypothetical interaction.

### Added — Native transcript quality validation (Phase A of the WhisperKit/Python parity audit)

The WhisperKit port dropped `no-transcribe`'s entire post-decode quality validation layer (`--validate warn/retry/flag` in `navt.py`) without replacing it — confirmed via a full parity audit (cloned the real `no-transcribe` repo and diffed its behavior against the Swift port). Two of four transcription settings turned out to be silent no-ops in the new pipeline: `numBeams` (recorded to `RecordingMeta` for display, but never passed to WhisperKit, which has no beam-search parameter anyway) and `validateMode` (setting existed in the UI, did nothing). This restores the validation half natively rather than reintroducing Python:

- **New `TranscriptValidation.swift`** — pure-Swift ports of `navt.py`'s `detect_hallucination_phrases` (same curated Norwegian/English YouTube-outro phrase denylist), `detect_gaps`, `detect_low_density_regions`, `detect_energy_mismatch` (reusing `StereoSplitter`'s existing RMS-energy Accelerate code for a mono channel), and `detect_repetition_loops`, plus a `validate`/`summarize` orchestrator mirroring the original scoring weights (gap: `-min(20, seconds)`, low density: `-5`, repetition: `-count*2`, hallucination phrase: `-10`, energy mismatch: `-8`).
- **`transcription.validateMode`** (warn/flag/none) is now actually wired into `TranscriptionService` for both the mono and per-channel stereo paths. `"warn"` attaches a `TranscriptValidationSummary` to the transcript; `"flag"` additionally marks overlapping segments `lowConfidence`. For the stereo pipeline, each RØDE channel is validated independently (own audio energy) and the two issue lists are combined into one summary for the final merged transcript. **`"retry"` (automatic re-transcription of flagged regions) is not implemented yet** — WhisperKit has no beam-count knob to escalate to like the old pipeline did, so it needs its own design; currently behaves the same as `"warn"`.
- **UI**: `TranscriptEditorView` now shows a small warning-triangle indicator and left-edge accent stripe (`AppColors.warning`, distinct from the existing orange anonymization-redaction highlight) on segments flagged in `"flag"` mode. `LibraryScreen`/`RecordingDetailView` show a "Kvalitetsvurdering" (quality score) row alongside the existing model/beams/processing-time details, cached via new `TranscriptMeta.validationScore`/`validationIssueCount` fields (same pattern as the pre-existing `numBeams` cache) so the library list doesn't need to parse full transcript JSON.
- **Compliance**: validation never logs matched phrase text, segment text, or any other transcript content to the audit log — only the mode, score, and issue count (`AuditEventType.transcriptValidationCompleted`). The richer per-issue detail (fixed denylist phrases, computed descriptions like "12.3s gap") lives only in the transcript's own JSON, at the same sensitivity level as the transcript itself.
- Detector functions have no WhisperKit dependency, so — unlike almost everything else touched this session — they were verified with real, executed test runs (not just typechecking): 23 assertions across all five detectors plus the scoring/flagging orchestration, run via a standalone `swiftc`+XCTest-framework harness since this sandboxed environment blocks `swift test`'s package resolution. Real unit tests are checked in at `tests/ClioTests/TranscriptValidationTests.swift`.
- Full write-up, including the broader parity-audit findings (verbatim/"Ordrett" mode was already dead code in the old Python pipeline too, HuggingFace vs. WhisperKit trade-offs) in the session's `plan.md`.

### Removed — "Transkripsjonsnøyaktighet" (`numBeams`) setting

Follow-up to the parity audit above. `numBeams` (1–5, "Transkripsjonsnøyaktighet" in Settings) was already a display-only no-op since the WhisperKit port: read from `UserDefaults`, recorded to `RecordingMeta` for a "Nøyaktighet" badge, but never passed into a real WhisperKit decode option — and it can't be, since WhisperKit has no beam-search parameter at all (confirmed against its real `DecodingOptions` source). Two earlier attempts this session to fake an equivalent via `temperatureFallbackCount` were tested against real audio and made quality measurably *worse* (see "Attempted and reverted" above), so rather than try a third guess, removed the setting entirely instead of continuing to show researchers a control that does nothing:

- Removed the Picker and description text from `TranscriptionSettingsView.swift`, the `@AppStorage` property, and its `UserDefaults` default registration in `main.swift`.
- Removed the now-meaningless "Nøyaktighet" badge from `LibraryScreen.swift` and `RecordingDetailView.swift`, and the `numBeams`/`validationIssueCount` write in `TranscriptionRunner.swift`.
- Removed `TranscriptMeta.numBeams` from `RecordingMeta.swift` — existing recordings with this key in their saved JSON decode unaffected (Codable silently ignores unknown keys).
- `PillButton.swift`'s `TranscriptionProgressView` time-remaining estimate no longer takes a `numBeams` parameter — its "beam scale" multiplier was calibrated at what was always its effective default anyway (every call site either omitted the parameter or read a `UserDefaults` value that only the now-removed picker ever changed), so the estimate is numerically unchanged.
- Also corrected the "Prøv på nytt" (`"retry"`) validation-mode description in Settings, which still claimed "re-transcribes with higher beam width" — now honestly states it isn't implemented yet and currently behaves like "Advar" (`"warn"`), matching the scoping decision above.
- Left "Ordrett" (verbatim) mode's existing Settings disclosure as-is — it already accurately discloses the fallback-to-clean-model behavior, and remains accurate independent of the parity audit's finding that the old Python pipeline's `--verbatim` flag never worked either.

### Fixed — Duplicate stereo transcription lines and unwarranted "unclear audio" placeholders

Real-world testing (user-provided screenshot of an actual interview transcript) confirmed the stereo pipeline still produces duplicate lines — the same utterance transcribed independently on both RØDE channels, appearing twice under both speaker labels at nearly the same timestamp with slightly different wording per channel. Root cause: the existing per-channel cross-talk suppression (`StereoSplitter.ChannelEnergy.dominantRange`, run in `tighten()`) only asks *"was this channel dominant for ≥0.3s within this segment's own nominal span?"* — it never compares against what the *other* channel produced for the same moment. When the two RØDE Wireless Micro transmitters pick up a speaker at comparable volume (e.g. participants sitting close together), each channel can independently pass its own dominance check for the very same utterance, and `mergeTranscriptionResults` had no deduplication step at all — it only concatenates and sorts by timestamp.

- **New `StereoSplitter.deduplicateCrossTalk(left:right:energy:)`**, run after per-channel tightening and before merge. For every pair of segments (one per channel) whose tightened time ranges overlap by at least half the shorter segment's duration, keeps only one: prefers real text over `NativeTranscriptionEngine.unclearAudioPlaceholder` regardless of energy (see below), otherwise keeps whichever channel had the greater summed RMS energy specifically over the *overlap* window (a more direct measure than either segment's own looser nominal span), with left winning ties (matching the merge step's existing tie-break convention). New `ChannelEnergy.summedEnergy(from:to:)` helper supports this.
- **Also directly addresses a second reported symptom**: segments showing `[uklart lydavsnitt]` ("unclear audio") for audio the researcher confirmed, by listening, was *not* actually unclear. Exposed the placeholder string as `NativeTranscriptionEngine.unclearAudioPlaceholder` so the new dedup step can recognize it — when one channel hallucinates the placeholder but the other channel's mic picked up the same moment clearly, the real transcription now wins instead of both surviving as a duplicate pair (one real, one bogus).
- Verified with real, executed unit tests (not just typechecking) — 10 assertions in `tests/ClioTests/StereoSplitterDedupTests.swift` covering non-overlapping segments, energy-based resolution in both directions, tie-breaking, placeholder-vs-real-text preference (including the case where the louder channel is the one hallucinating and must still lose), both-sides-placeholder fallback to energy, and the overlap-fraction threshold — run via the same standalone `swiftc`-compiled harness (no XCTest/SPM) used for the `TranscriptValidation` detectors, since this environment still can't run `swift test`. `TranscriptionService.swift`/`StereoSplitter.swift`/`NativeTranscriptionEngine.swift` also re-verified via `swiftc -typecheck` against the real `WhisperKit.swiftmodule` — zero errors.
- As always in this environment: still no CoreML runtime to confirm against the actual reported recording. This is a deterministic post-processing pass over already-computed segments/energy data (not a change to WhisperKit's decode behavior), which is a meaningfully lower-risk category of fix than the two earlier reverted attempts — but real-audio confirmation against the reported interview is still needed.

### Added — Real "Ordrett" (verbatim) transcription mode

The verbatim checkpoint (`NbAiLab/nb-whisper-large-verbatim`) is now actually converted and bundled — "Ordrett" mode in Settings switches to genuinely different model weights instead of silently falling back to the clean model. Also corrected a factual error in `docs/MODEL_SETUP.md`: it previously claimed the old Python `no-transcribe` subprocess "switched between two model checkpoints for renset/verbatim" — direct inspection of `navt.py`'s source (and its full commit history) confirms that was never true; its `--verbatim` flag was dead code, so verbatim mode never actually worked in the Python pipeline either.

- Ran the exact conversion recipe already documented in `docs/MODEL_SETUP.md` §1b (`whisperkittools`, same as the already-bundled clean model) end-to-end: `MelSpectrogram.mlmodelc`, `AudioEncoder.mlmodelc` (PSNR=49.3), `TextDecoder.mlmodelc` (PSNR=41.4), plus all 8 tokenizer files, now present at `Resources/WhisperKitModels/NbAiLab_nb-whisper-large-verbatim/` (2.9GB, matching the clean model's structure and size).
- One real gotcha found and documented: `whisperkittools`'s own precision QA gate (`TEST_PSNR_THR = 35` in its test suite, calibrated for the official OpenAI Whisper family) failed on one attempt at 32.1 PSNR for this NB AI-Lab fine-tune, then passed comfortably (41.4) on a clean retry with no code changes — apparent run-to-run numerical variance in PyTorch tracing, not a fundamental incompatibility. Documented in `MODEL_SETUP.md` for future re-conversions.
- No Xcode project changes needed — `Resources/WhisperKitModels` is a whole-folder reference with a build-phase script that copies its entire contents, so the new model folder is picked up automatically on the next build.
- `NativeTranscriptionEngine.isVerbatimBundled` now returns `true`; the "Ordrett-modellen er ikke bygget inn i denne versjonen ennå" fallback disclosure in Settings no longer applies.

### Fixed — Stale, contradictory distribution documentation in `packaging/`

`packaging/ExportOptions.plist` and `packaging/DISTRIBUTION.md` still described the pre-WhisperKit-port architecture — a Developer-ID-signed, notarized DMG with App Sandbox deliberately disabled to allow spawning an embedded Python subprocess (`embed-python.sh`, deleted when the app moved to WhisperKit — this doc still referenced it as if it ran automatically on every Release build). Confirmed directly by the project owner: Clio actually targets the Mac App Store / TestFlight, which requires App Sandbox unconditionally — this contradicted the `ENABLE_APP_SANDBOX = YES` already set in both Xcode build configurations and the WhisperKit port commit's own claim of "confirmed working in production via TestFlight distribution." This stale documentation directly caused an incorrect claim earlier in this session that Clio doesn't target the App Store at all.

- `packaging/ExportOptions.plist`: `method` corrected from the non-sandboxed `developer-id` to `app-store-connect` (Apple's current, non-deprecated export method for App Store/TestFlight submissions); removed the now-inverted "Do NOT enable App Sandbox" comment.
- `packaging/DISTRIBUTION.md`: added a prominent warning banner explaining the whole document is stale and pointing at the real submission path (Xcode Organizer / `xcodebuild -exportArchive` with the corrected `ExportOptions.plist`) instead of the DMG/notarization/Python-embedding steps below it — kept the rest of the document for historical reference rather than fabricating a new runbook for a submission process not directly observed.

### Fixed — Real bug: hallucinated placeholder over audio the researcher confirmed was clearly audible

Real-world testing turned up a case the earlier cross-channel dedup fix couldn't reach: a full 30-second segment showing `[uklart lydavsnitt]` where the researcher confirmed, by listening, the audio is "crystal clear." Unlike the duplicate-lines case, there was no overlapping segment on the other RØDE channel to prefer instead — nothing else in the pipeline could recover this content.

- **New `AudioWAVConverter.extractSubClip(wavURL:start:end:padding:)`** extracts an isolated sub-range of an existing WAV (with configurable padding, clamped to file bounds). **New `TranscriptionService.repairUnclearSegments(...)`**, wired into both the mono and per-channel stereo transcription paths: whenever a segment's entire text is the unclear-audio placeholder, re-transcribes just that narrow time range in isolation and replaces the text only if the retry produces real content — mirrors `no-transcribe`'s own `_fill_gap` mechanism, which re-transcribed short isolated clips for the same reason (a decoder given just the narrow clip, with its own true start/end instead of a mid-stream window of a much longer file, sometimes produces a materially different, better result). Strictly improve-or-leave-unchanged: a repeat failure just leaves the original placeholder in place.
- **Found and fixed a real, separate bug while building and testing this**: `AVAudioFile.read(into:frameCount:)` is not guaranteed to fill the requested frame count in a single call — confirmed empirically (a plain in-bounds request came back ~2% short). The first version of `extractSubClip` used a single unlooped read call and silently truncated clips. Fixed with the same chunked-read-until-full-or-EOF loop already used elsewhere in this file (`convertToWAV`, `splitStereoM4A`). Also found and fixed a related crash risk: the initial version read using `AVAudioFile`'s default (unpinned) `processingFormat`, which is typically float32 regardless of on-disk bit depth — mismatched against the Int16 writer and would have crashed with an uncatchable Objective-C exception on first real use, the exact failure mode already documented (and avoided) in `convertToWAV`'s own comments. Fixed by pinning the read format to Int16 interleaved, matching the write side.
- Verified with real, executed tests — both a standalone `swiftc` harness (to catch the frame-count and format bugs above before they were fixed) and real checked-in tests at `tests/ClioTests/AudioWAVConverterSubClipTests.swift` (4 tests: exact range + padding, padding-clamping at file bounds, out-of-bounds throws, zero-padding exact range), using a synthetic WAV whose samples encode their own index so extraction can be verified byte-exact, not just by length. `TranscriptionService.swift`/`AudioWAVConverter.swift` also re-verified via `swiftc -typecheck` against the real `WhisperKit.swiftmodule` — zero errors.
- As always: no CoreML runtime here to confirm the repair actually improves output against the specific reported recording — the sub-clip extraction is now real-tested and correct, but whether re-decoding this particular kind of moment in isolation actually recovers real text (versus hallucinating a placeholder again) can only be confirmed on a real Mac.

### Fixed — Real regression: `deduplicateCrossTalk` was incorrectly deleting distinct, legitimate speech

User reported the entire beginning of a recording missing transcription and massive gaps throughout, explicitly noting diarization "was perfect" in earlier testing and had regressed. This was a genuine bug in this session's own cross-channel dedup fix (above), not a pre-existing threshold/sensitivity issue — no audio-level or channel-separation settings changed.

**Root cause**: `deduplicateCrossTalk` measured time overlap as a fraction of the *shorter* of the two segments' own durations. This means any short segment — a brief interjection, an acknowledgement, or simply a segment that happens to be much shorter than one elsewhere — landing anywhere inside a much longer segment's time range on the other channel always scored ~100% "overlap," regardless of what either segment actually said. In a real interview with a long interviewer monologue and short informant interjections (or vice versa), this caused correct, distinct speech to be silently deleted throughout the transcript, not just genuine duplicates — a materially worse regression than the problem it was meant to fix.

- Added a **word-similarity gate** (case-insensitive word-set Jaccard similarity, `minWordSimilarity: Double = 0.3`) to the real-text-vs-real-text branch of `deduplicateCrossTalk`: two overlapping segments are now only treated as the same utterance duplicated across channels if their actual words are similar enough to plausibly be the same thing, not just because their time ranges overlap. The placeholder-vs-real-text branch is unaffected (a hallucinated placeholder never has meaningful words to compare, so time overlap alone is correctly sufficient there — verified this still works regardless of duration mismatch).
- The both-placeholders case (neither side has real content) now leaves both segments in place rather than guessing via energy comparison, since there's nothing meaningful to compare either way.
- Verified with real, executed tests: a standalone `swiftc` harness reproducing the exact regression shape (a long segment + a short, textually unrelated nested segment — now both survive) alongside the original true-duplicate case (near-identical text — still correctly deduplicates) and the placeholder-preference case (still correct regardless of duration). All 12 tests in `tests/ClioTests/StereoSplitterDedupTests.swift` (2 new, regression-specific) re-verified by actually invoking every test method against the real production code, not just typechecking — caught and fixed an unrelated brace-mismatch typo introduced while editing the test file in the process. `TranscriptionService.swift`/`StereoSplitter.swift` re-verified via `swiftc -typecheck` against the real `WhisperKit.swiftmodule` — zero errors.
- Still cannot confirm against the actual reported recording in this environment — needs real-world re-testing to confirm the missing content and gaps are resolved.

### Fixed — Root cause of persistent "large chunks missing": WhisperKit's own no-speech skip drops whole ~30s windows with zero trace

User reported large audio chunks (including "the entire beginning") still missing transcription after all prior fixes, and stated the RØDE setup diarized perfectly a month ago — pointing squarely at a real regression rather than a tuning issue. Rather than guess again, did a from-scratch audit: re-cloned `no-transcribe` (the previous local clone had uncommitted changes leaving it checked out near an old, since-reverted commit — reset to true `HEAD` first) and read WhisperKit's actual decode source (`TranscribeTask.swift`, `SegmentSeeker.swift`) directly from the cached SPM checkout, not just its public API surface.

**Root cause, found in WhisperKit's own `SegmentSeeker.findSeekPointAndSegments`**: with the default `noSpeechThreshold = 0.6`, if a decode window's no-speech probability exceeds the threshold (and `avgLogProb` isn't confident enough to override), WhisperKit skips the *entire* decode window — `seek += segmentSize; return (seek, nil)` — producing **no segment at all**, not even a placeholder. Since Clio's `NativeTranscriptionEngine` never set a `chunkingStrategy`, every long recording fell through to WhisperKit's default fixed ~30s-window seek loop, so a single no-speech misfire (plausible for NB-Whisper's fine-tuned checkpoint on cross-talk/accented audio, whose no-speech-token calibration likely differs from the base OpenAI checkpoints WhisperKit's default thresholds were tuned against) silently erases up to ~30 real seconds with zero trace — exactly matching "2:00 to 2:30 missing," "the entire beginning missing," and "massive gaps throughout."

`no-transcribe`'s own `navt.py` never disables this class of check either (HuggingFace's pipeline applies the same kind of no-speech/logprob heuristics internally) — its real defense is a second, independent, cause-agnostic safety net: `_fill_gap`, which re-transcribes any timeline gap wider than 5s in isolation regardless of why it's empty. Clio had no equivalent — `repairUnclearSegments` only retries segments that already contain the hallucination placeholder text, which a whole-window skip never produces.

- **`NativeTranscriptionEngine`**: set `options.chunkingStrategy = .vad`, WhisperKit's own purpose-built silence-aware chunker (`VADAudioChunker` + `EnergyVAD`), replacing the naive fixed-window seek loop that can cut windows mid-sentence regardless of audio content — the same motivation as `no-transcribe`'s own choice of large 30s/6s-stride windows, but using a more direct, officially-supported mechanism instead of re-deriving fixed-window heuristics. (Does not by itself prevent a no-speech misfire within a chunk — see below.)
- **New `TranscriptionService.repairTimelineGaps(...)`**, wired into both the mono and per-channel stereo paths (before `repairUnclearSegments`): mirrors `no-transcribe`'s `_fill_gap` exactly (`GAP_FILL_S = 5.0` → `gapThresholdSeconds`, `CONTEXT_S = 2.0` → reuses the existing `AudioWAVConverter.extractSubClip` padding). Scans the segment timeline for any span wider than the threshold with no segment at all — before the first segment, between two segments, or after the last — and re-transcribes each in isolation, splicing any real recovered text back into the timeline at the correct absolute position. Cause-agnostic by design: it doesn't matter *why* the gap is empty (no-speech misfire, VAD quirk, anything else), only that it is. Strictly additive — only ever inserts into a span that had nothing, never touches an existing segment.
- Pure gap-detection and timestamp-remap logic extracted into testable `static` functions (`TranscriptionService.detectTimelineGaps`, `.remapRecoveredSegment`) rather than inlined in the async WhisperKit-calling method, specifically so the error-prone boundary math (gap edges, subclip-padding offset, clamping recovered speech to the gap's own bounds) could be verified without a real decode. Verified via a real, executed standalone `swiftc` harness (27 assertions: no-gap, mid-stream gap, gap-before-first, gap-after-last, whole-file-empty, sub-threshold gap ignored, overlapping segments don't go negative, unsorted input, timestamp remap + both clamp directions, rejecting spans entirely outside the gap) — all pass — plus a new checked-in `tests/ClioTests/TranscriptionGapFillTests.swift`. Full project re-verified via `swiftc -typecheck` against the real `WhisperKit.swiftmodule`/`ArgmaxCore` (confirmed `DecodingOptions.chunkingStrategy` and `ChunkingStrategy.vad` exist exactly as used) — zero errors.
- **Separately investigated and confirmed correct, no change needed**: `wordTimestamps = false` (set earlier this session) already matches `no-transcribe`'s own final, hard-won choice — its commit history shows an earlier version used word-level timestamps for the main pass, then explicitly reverted to sentence-level after finding word-level "very experimental" per HuggingFace and a direct cause of "persistent gaps," using word-level only for isolated short-clip repairs (exactly the role `repairUnclearSegments`/`repairTimelineGaps` play in Clio). Also traced whether WhisperKit's `usePrefillPrompt = true` risks the same hallucination-cascade problem `no-transcribe` explicitly guards against via `condition_on_prev_tokens = False` — confirmed via `TranscribeTask.swift` that `usePrefillPrompt` only prefills special/task/language tokens per window and never feeds a previous window's transcribed text forward (`promptTokens` stays unset), so Clio's configuration already behaves like `condition_on_prev_tokens = False` with no change needed.
- **Confirmed a real, unavoidable capability gap, not a bug**: NB-Whisper's own model card recommends `num_beams=5` ("greatly increases accuracy") for best results, and `no-transcribe` uses `num_beams=3`. WhisperKit has a real `BeamSearchTokenSampler` in its source tree, but `TranscribeTask.decodeWithFallback` hardcodes `GreedyTokenSampler` unconditionally — there is no `DecodingOptions` field or code path to select beam search at all in the version Clio depends on. This is a genuine accuracy gap between the Python pipeline and the WhisperKit port with no fix available from Clio's own source; flagging honestly rather than working around it.
- As always: no CoreML runtime here to confirm against the actual reported recording — the boundary logic is now real-tested and correct, but whether this recovers the specific missing audio the user heard can only be confirmed on a real Mac.

### Added — Detect RØDE capture-app "merge channels" hardware misconfiguration

User discovered the actual root cause behind a long stretch of "diarization is broken" reports this session: the RØDE capture app itself had been reset to "merge" channel mode instead of "split," summing both wireless mics into one mono signal duplicated onto both stereo channels *before Clio ever receives the file*. No software-side energy analysis or dedup logic (`ChannelEnergy`, `deduplicateCrossTalk`, or anything else touched this session) can recover per-speaker separation once this has happened — there is genuinely nothing left to separate. This had nothing to do with any of the transcription-pipeline changes investigated earlier.

Added detection so this fails loudly and immediately instead of silently, next time:

- **New `StereoSplitter.isLikelyMergedChannels(_:)`**: compares the per-window RMS energy `analyzeChannelEnergy` already computes between the two channels. Genuinely independent RØDE mics show large per-window asymmetry whenever one person speaks — the original cross-talk gating design measured ~18 dB separation on a real recording (quieter channel at roughly 1/8th the louder one's RMS). A merged/duplicated signal shows essentially none, because both channels carry the same audio. Judges only windows with real signal (above the existing silence floor) and requires a minimum count of them, so short or mostly-silent recordings aren't judged either way.
- Wired into `TranscriptionService.runStereoTranscription`, right after the channel split and before either channel is transcribed: when detected, skips the (otherwise pointless and wasteful) double transcription of identical audio entirely, runs a single mono pass instead, and returns a result with `diarizationRun = false` plus a new top-level `TranscriptValidationIssue.Kind.mergedChannelsDetected` issue (Norwegian detail text explaining the likely cause and pointing at the RØDE app's channel setting) — scored as the dominant issue (score 0) since diarization isn't merely degraded here, it's fundamentally impossible for this recording.
- New `AuditLogger.EventType.transcriptionMergedChannelsDetected` — logs only the source filename, never transcript content.
- Verified via a real, executed standalone `swiftc` harness (6 assertions: identical channels, near-identical with encoding-noise-level jitter, genuine ~18dB dual-mic separation correctly NOT flagged, mostly-silent and completely-silent recordings correctly not judged either way, and a single coincidental near-equal window among otherwise-genuine separation not flipping the verdict) — all pass — plus checked-in `tests/ClioTests/StereoSplitterMergedChannelsTests.swift`. Full project re-verified via `swiftc -typecheck` against the real `WhisperKit.swiftmodule` — zero errors.

### Fixed — Reverted same-day `chunkingStrategy = .vad` change; found it multiplies the exact damage it was meant to prevent

User reported new, specific symptoms after the previous fix round: a placeholder over confirmed-clear audio surviving repair, several new precise-timestamp skips scattered through one recording, a new hallucinated interjection ("Hvorfor det?"), and one point where segment sequence/ordering looked wrong — described as materially different and worse than before, "not a problem previously." That pattern (several *new* named failure points after a same-day change, not the same old symptom persisting) pointed at the VAD chunking change itself rather than another tuning gap.

Traced `VADAudioChunker.chunkAll` + `WhisperKit.transcribe(audioArray:)`'s `.vad` branch again, this time following where each VAD chunk's audio actually goes: it's re-transcribed via a **fully separate, recursive** `self.transcribe(audioArray:...)` call per chunk — not decoded inline within one continuous pass. Each of those recursive calls runs `TranscribeTask.run`'s own seek loop *including its own `windowClipTime`-based end-of-clip trim* (`while seek < seekClipEnd - windowPadding`, the same "prevent hallucinations at the end of the clip" trade-off already present in the plain non-VAD path). Without VAD, that trim happens once, at the very end of the whole file (≤1s lost, worst case). With VAD enabled, a single long recording gets split into dozens of chunks, each independently trimmed the same way — multiplying a bounded, once-per-file loss into scattered, repeated losses throughout the recording. Each VAD chunk also restarts the decoder's prompt/KV-cache from a blank slate (`prepareDecoderInputs(withPrompt: [startOfTranscriptToken])`), which is exactly the kind of context-free boundary condition already known (from `no-transcribe`'s own history) to invite hallucinated filler content — matching the new "Hvorfor det?" interjection appearing right at a skip.

- Reverted `NativeTranscriptionEngine`'s `options.chunkingStrategy = .vad` back to the default (unset). Kept `repairTimelineGaps` (strictly additive, doesn't change the main decode path) as the actual safety net for missing content instead of trying to prevent gaps by changing how the whole file gets chunked.
- **Also addressed why a repair retry can reproduce the exact same placeholder it was meant to fix**: `repairUnclearSegments`/`repairTimelineGaps` previously re-decoded an isolated clip with identical `DecodingOptions` to the main pass, including `noSpeechThreshold = 0.6`. If a clip's acoustic content deterministically triggers a no-speech misfire (plausible for NB-Whisper's fine-tuned calibration on cross-talk audio), the retry hits the identical skip and "fixes" nothing. Added `NativeTranscriptionEngine.transcribe(...disableNoSpeechSkip:)`, wired to `true` only for these two repair call sites (never the main first pass) — safe because both retries already only ever replace content if the result is real, non-placeholder text, so removing this one gate on a retry-only path can't produce a worse outcome than the placeholder already there.
- Full project re-verified via `swiftc -typecheck` against the real `WhisperKit.swiftmodule` — zero errors.
- **Still unconfirmed against the actual reported recording** — this environment has no way to run WhisperKit against real audio, and (checked directly) the specific recording behind this report isn't present in this machine's local Clio library either, so this remains a well-evidenced but unverified fix pending the user's own re-test.

### Fixed — Real, confirmed bug: gap-fill repair ran before cross-talk dedup, so dedup silently deleted the very content repair had just recovered

User shared a real transcript screenshot (a genuine interview, "Intervju 1 20260901 092044") showing a ~58 second span (1:29–2:27) with **no segment at all** on either speaker — the exact "large chunk missing" failure the earlier fixes were meant to close, reappearing in a fresh test. Since the user could not immediately confirm whether this was tested against the very latest build, treated it as a live, unresolved bug rather than waiting, and re-examined this session's own pipeline ordering directly instead of hypothesizing further about WhisperKit internals.

**Root cause, found by re-reading `runStereoTranscription`'s actual call order**: `repairTimelineGaps`/`repairUnclearSegments` ran *inside* `runNativeMono`, which returns and completes **before** the stereo orchestrator's own `dominantRange` tightening (Step 2b) and `deduplicateCrossTalk` (Step 2c) run on the result. Both of those later stages can legitimately discard a segment for any span where channel energy is quiet or ambiguous on both channels — which is exactly the acoustic signature of audio that triggers WhisperKit's no-speech skip in the first place. So the sequence was: WhisperKit drops a window → gap-fill recovers it → the very next pipeline stage deletes it right back out, because the same low/ambiguous energy that caused the original drop also fails the "was this channel actually dominant here" check. A self-inflicted bug introduced earlier the same day, undoing its own fix one stage later.

- Extracted a new `transcribeChannelRaw(...)` (WAV-convert + raw WhisperKit transcribe only, no repair, caller owns the WAV file) and rewired the dual-channel path in `runStereoTranscription` to call it directly instead of the repair-including `runNativeMono`. Repair now runs **after** `dominantRange` tightening and `deduplicateCrossTalk`, immediately before merge, so anything repair recovers is never re-litigated by cross-talk logic afterward. `runNativeMono` itself is unchanged for its other caller (the merged-channels fallback), which has no subsequent dedup step to interact with.
- **Also changed gap-fill from per-channel-independent to mutual-only**: naively repairing each channel's gaps independently at this later point introduces a *different* real risk — a gap on only one channel usually just means the other person was talking and that mic legitimately picked up nothing, and blindly re-decoding it with `disableNoSpeechSkip` could hallucinate a duplicate line for a moment the other channel already transcribes correctly. New `repairMutualTimelineGaps(...)` only attempts recovery for spans missing from **both** channels' own timelines at once (computed via interval intersection of each channel's independently-detected gaps), trying the left channel's audio first and falling back to the right — directly targeting the reported symptom (nothing on either channel) without reintroducing one-sided duplicate risk.
- Verified via two real, executed standalone `swiftc` harnesses: the reordering itself via a full project `swiftc -typecheck` (zero errors — confirms the new call graph, tuple destructuring for `async let` pairs, and `inout` result mutation all compile correctly), and the new mutual-gap intersection math via 9 assertions (exact-match, adjacent-non-overlapping, partial-overlap-clipped-to-intersection, one-channel-fully-covered, one-sided-gaps-at-different-times-not-flagged, the actual reported bug shape at 1:29–2:27, sub-threshold intersection ignored, multiple disjoint mutual gaps) — all pass — plus checked-in `tests/ClioTests/TranscriptionMutualGapFillTests.swift`.
- **Still unconfirmed against the actual reported recording** for the same reason as always: no CoreML runtime here, and the file isn't present in this environment. This is the fourth round of fixes to this exact pipeline today without an ability to close the loop with real audio — flagged explicitly rather than implied to be resolved.

### Fixed — Found the actual recording on disk, ran real signal analysis and a real cross-implementation comparison, confirmed root cause with direct evidence (not just source-code reasoning)

Previous rounds this session repeatedly hit a wall: no way to test against real audio, only source-code tracing and synthetic-data tests. This round broke through that wall. The earlier "recording not found" conclusion was itself a bug in the investigation — Clio is a sandboxed app, so its real `~/Library/Application Support/Clio/` is under `~/Library/Containers/no.nav.cliotranscribe/Data/...`, not the unsandboxed path checked earlier. Once found, the user's actual test recording (`test_20260901_191526`, a real `audio.m4a` + `meta.json` + `transcript.txt`, mono/no-channel-split test) was available directly on disk.

**Real signal analysis, not guessing**: extracted the file's actual waveform (ffmpeg → 16kHz mono WAV) and computed real RMS energy per second across the whole recording, specifically the tail region reported as `[uklart lydavsnitt]` (roughly 80–101s of a 101s file). Energy there (−34 to −41 dBFS) was normal, clearly-audible speech level — comparable to or louder than many earlier segments that transcribed perfectly correctly (e.g. −55 to −67 dBFS elsewhere). This directly ruled out "quiet/ambiguous audio" or genuine silence as the cause.

**Real cross-implementation comparison, not just theory**: the same `no-transcribe-venv` Python environment already on this machine (from earlier session work) has `transformers`/`torch` fully installed. Extracted the exact failing tail region and ran it through `NbAiLab/nb-whisper-tiny` — a far weaker checkpoint than the `large` model Clio actually uses — via the HuggingFace `pipeline()` API (the old `no-transcribe` pipeline's own approach). It produced a fully coherent, legible Norwegian transcript for the entire span, correctly picking up the user listing objects around them ("med basilikummen på bordet og capsen på bordet... litt nesespray i... briller, og headset og mikrofoner og en radio"). Direct proof: the audio was never the problem. Something specific to Clio's WhisperKit decode configuration was rejecting recoverable, real content.

**Root cause, further narrowed**: `disableNoSpeechSkip`'s earlier fix only cleared `noSpeechThreshold`. Re-read `DecodingFallback.init(options:isFirstTokenLogProbTooLow:noSpeechProb:compressionRatio:avgLogProb:)` in WhisperKit's own source and found the temperature-retry loop has two *other* gates with the same "reject and never truly recover" shape: `compressionRatioThreshold` (default 2.4 — rejects a decode as "too repetitive") and `logProbThreshold` (default −1.0 — rejects as "not confident enough"), both of which force a re-roll at a *higher, noisier* temperature rather than accepting a good-enough answer. The confirmed-recoverable content here is exactly the shape that trips a naive repetition heuristic: a rapid enumeration of short, similarly-structured noun phrases (a listing pattern, not a hallucination loop) — genuinely low-entropy text that a compression-ratio check can't distinguish from a repetition failure, no matter which temperature it's re-tried at, since the actual content's structure doesn't change with temperature.

- Extended `disableNoSpeechSkip` (retry-only, both repair call sites, never the main pass) to also clear `compressionRatioThreshold` and `logProbThreshold`, not just `noSpeechThreshold`. Same safety argument as before: these retries only ever replace a segment when the result is real, non-placeholder text, so relaxing quality gates that exist purely to trigger a re-roll (not to skip outright) can only help or do nothing on a retry-only path — never make the outcome worse than the placeholder already there. Deliberately scoped to retries only, not the main pass, where these gates still serve their real purpose (catching genuine hallucination loops across a whole recording).
- Full project re-verified via `swiftc -typecheck` — zero errors.
- This is the first fix this session backed by direct, real evidence from the actual reported audio and a real working comparison transcription, rather than source-code inference alone — still can't run WhisperKit itself in this environment, but the underlying claim ("this audio is transcribable, something in the decode config is rejecting it") is now empirically demonstrated, not hypothesized.

### Fixed — Empirically falsified my own previous fix, found the real mechanism was untouched, added a genuinely different lever

The threshold-relaxation fix above was tested for real: rebuilt (confirmed via build timestamp — binary 4 minutes newer than the source edit) and re-ran the *exact* recording that exposed the bug. Output was **byte-for-byte identical**, placeholder included. If `noSpeechThreshold`/`compressionRatioThreshold`/`logProbThreshold` had actually been rejecting a usable decode, disabling them would have changed something about which attempt got accepted. It changed nothing — the only way that's possible is if `DecodingFallback.init(...)` never flagged `needsFallback` for this clip in the first place, meaning WhisperKit's temperature-fallback ladder (0.0 → 1.0) never even started. The model wasn't gated out; it was **confidently wrong** — a high enough `avgLogProb`, low enough `compressionRatio` and `noSpeechProb`, while still greedily decoding hallucinated/empty content. None of the three gates catch that, by design — they all assume the model "knows" when it's struggling.

- Added `NativeTranscriptionEngine.transcribe(...forcedTemperature:)` — lets a caller force a non-zero starting temperature instead of relying on WhisperKit's own fallback ladder (which never triggers if no gate is tripped). New `TranscriptionService.retryDecodeEscalating(...)` tries, in order: relaxed gates at default temperature, then forced temperature 0.4, then 0.8 — stopping at the first attempt producing real, non-placeholder text. Shared by both `repairUnclearSegments` and `recoverGap` (used by both timeline-gap-fill paths) instead of duplicating the retry logic.
- **Ran a further real, empirical check before committing to this**: extracted the same failing audio and forced *pure* greedy decoding (`temperature=0.0, do_sample=False`, bypassing any fallback ladder entirely) through the Python/HuggingFace pipeline — it *still* produced a fully coherent transcript with the tiny model, as did explicit forced sampling at `temperature=0.8`. This means the "greedy decoding is uniquely the problem" theory isn't fully confirmed either — greedy decoding of this content is not inherently broken in general. Reporting this honestly: temperature escalation is a reasonable, safe (retry-only, can only help-or-match) mitigation given the confirmed evidence, not a proven fix. The consistent, harder-to-explain difference remains specific to Clio's exact CoreML-converted `large` checkpoint and/or WhisperKit's own Swift decode implementation, which cannot be directly inspected or run in this environment.
- Full project re-verified via `swiftc -typecheck` — zero errors.
- Documented plainly for the next round: if this still doesn't recover the content, the next diagnostic step is comparing WhisperKit's own mel-spectrogram/tokenizer preprocessing against HuggingFace's for this exact clip, or testing whether the bundled CoreML `large` conversion itself has a quality regression the smaller HF checkpoints used for comparison don't share — neither of which is testable without a real macOS+Xcode+CoreML session actually running WhisperKit.

### Fixed — Confirmed real progress from the temperature-escalation fix, plus one new small artifact it exposed

User re-tested and shared a new screenshot: the `[uklart lydavsnitt]` placeholder is **gone**, replaced with real, legible content ("Laptopen som åpner, den tar opp 1.25, 1.26, 1.27.") — closely matching what the earlier HuggingFace comparison test independently recovered for the same audio ("...tar opp 1,25, 26, 27..."). The forced-temperature retry escalation worked for real, on the first genuinely different (non-byte-identical) result all session. Real, working progress, not a wall of theory this time.

It also exposed one new, narrow issue: a stray, isolated `>` character appearing as its own segment's entire text — clearly a tokenizer/decode artifact (Whisper-family models represent timestamps as bracketed tokens internally; a partially-decoded boundary case can leak a lone bracket character), not real transcribed speech content.

- `NativeTranscriptionEngine.sanitize(_:)` now also treats a segment whose trimmed text contains **no letter characters at all** (just stray punctuation/symbols) the same as an empty decode — replaced with the existing `unclearAudioPlaceholder`. No transcribable Norwegian utterance is ever letter-free, so this can't misfire on real content, and it means `TranscriptionService`'s repair mechanisms (which specifically target that placeholder) get a chance to recover this kind of artifact too, exactly like a fully-empty decode.
- Verified via a real, executed standalone `swiftc` harness (7 assertions: stray `>` alone → placeholder, punctuation-only → placeholder, real Norwegian text → unchanged, empty/whitespace-only → placeholder, exact hallucination marker → placeholder, pure-digit-only text → placeholder as a deliberate, accepted trade-off, short real Norwegian word → unchanged) — all pass.
- Full project re-verified via `swiftc -typecheck` — zero errors.

### Changed — Replaced WhisperKit with whisper.cpp as the transcription engine

After repeated real-world quality regressions on WhisperKit (missing/dropped
audio chunks, hallucinated placeholders, a confirmed-unfixable lack of any
beam-search decode path), inspected `/Applications/Jojo.app` (VG's
Mac-App-Store-distributed Norwegian transcription app) via legitimate bundle
inspection (`otool -L`, `codesign`, embedded build-path strings) and
confirmed it uses **whisper.cpp**, not WhisperKit/CoreML — no
`CoreML.framework`/`Speech.framework` linkage, whisper.cpp-specific symbols
(`whisper_backend_init`, `ggml-metal.m`) present instead. Validated the
switch for real before committing to it, not just on paper:

- Cloned `ggml-org/whisper.cpp`, built a real macOS arm64 static
  library + `.xcframework` from source (Metal/Accelerate/BLAS backends all
  detected), confirmed via `nm` that real beam-search symbols are compiled
  in — unlike WhisperKit, whose `TranscribeTask.decodeWithFallback`
  hardcodes `GreedyTokenSampler` unconditionally with no beam-search code
  path at all.
- Confirmed NB AI-Lab publishes official GGML weights directly on
  HuggingFace for both the clean (`NbAiLab/nb-whisper-large`) and verbatim
  (`NbAiLab/nb-whisper-large-verbatim`) checkpoints — no local CoreML-style
  conversion step needed for either, unlike the WhisperKit path.
- Ran the exact recording that had exposed repeated WhisperKit failures all
  session (`test_20260901_191526`, ~101s) through both `whisper-cli` and a
  custom Swift wrapper, with real beam search (width 5) and the real
  production `large` GGML q5_0 model — produced a complete, continuous,
  accurate transcript covering the entire file, including every region
  WhisperKit had dropped or garbled across multiple fix rounds this
  session.
- New `Sources/Clio/Services/WhisperCppEngine.swift` — actor wrapping the
  whisper.cpp C API, matching `NativeTranscriptionEngine`'s parameter shape
  exactly (`verbatim`, `disableNoSpeechSkip`, `forcedTemperature`,
  `temperatureFallbackCount`) plus a genuine `beamSize` parameter, so every
  existing call site (main pass, gap-fill repair, escalating-temperature
  repair) swapped over without changing argument shapes. Maps
  `disableNoSpeechSkip`/`forcedTemperature`/`temperatureFallbackCount` onto
  whisper.cpp's real equivalents (`no_speech_thold`/`entropy_thold`/
  `logprob_thold`, `temperature`/`temperature_inc`).
- Downloaded and bundled **both** GGML checkpoints (~1.08GB each) under
  `Resources/WhisperCppModels/` — "Ordrett" (verbatim) mode is now backed
  by genuinely different model weights under whisper.cpp too, not a
  fallback-to-clean placeholder.
- `TranscriptionService` now calls `WhisperCppEngine` exclusively at all
  three transcription call sites (main pass, stereo per-channel pass,
  consensus-repair retry). `NativeTranscriptionEngine`/WhisperKit is kept
  in the source tree (not deleted) but is no longer called by the live
  pipeline.
- Manually built a real `whisper.xcframework` (arm64-only, matching Clio's
  own architecture restriction) and registered it in
  `Clio.xcodeproj/project.pbxproj` (Frameworks build phase, Embed
  Frameworks copy phase, `FRAMEWORK_SEARCH_PATHS`), plus registered
  `WhisperCppEngine.swift`/`TranscriptionAccuracyLevel.swift` as Sources —
  per this repo's dual-build-system rule (SwiftPM auto-discovers new files;
  Xcode requires explicit registration or it fails with "Cannot find
  '<Type>' in scope").
- **Verified with a real, complete `xcodebuild -project Clio.xcodeproj
  -scheme Clio build`** (not just `swiftc -typecheck`) — confirmed
  `whisper.framework` genuinely links into the compiled binary (`otool -L`
  on `Clio.debug.dylib`), both GGML models land in the built app bundle's
  `Contents/Resources/WhisperCppModels/`, and the app signs successfully.
  This is the first time this session's transcription-engine changes could
  be validated against a real, complete build rather than only a
  typecheck.

### Restored — "Transkripsjonsnøyaktighet" (transcription accuracy) setting, now backed by real beam search

Re-added the 5-level picker to `TranscriptionSettingsView` (new
`transcription.accuracyLevel` `@AppStorage` key, wired through
`TranscriptionRunner` into `TranscriptionService.transcribe`). Unlike the
version removed earlier this session (which had become a fake control once
WhisperKit's lack of beam search made `numBeams` a no-op), this maps
directly onto whisper.cpp's real `whisper_full_params.beam_search.beam_size`
— the same real lever the original Python `no-transcribe` pipeline's
`num_beams` used, restored honestly rather than faked:

- **Raskest** → greedy (no beam search).
- **Rask** → beam width 2.
- **Middels** (default) → beam width 5, NB-Whisper's own model-card
  recommendation for best accuracy.
- **Treg** → beam width 5 + proactive consensus repair on every segment.
- **Svært treg** → beam width 8 + proactive consensus repair.

### Fixed — "Upload Symbols Failed" for `whisper.framework` on real App Store Connect archive/upload

Archived and uploaded the app for real (Xcode Organizer, `scripts/archive.sh`)
to sanity-check the whisper.cpp integration end-to-end — App Store Connect
accepted the upload but warned: *"The archive did not include a dSYM for the
A with the UUIDs [B8F7A640-...]. Ensure that the archive's dSYM folder
includes a DWARF file for A with the expected UUIDs."* ("A" is Xcode
Organizer's fallback label when it can't resolve a proper module name for
the missing dSYM — confirmed via `dwarfdump --uuid` that the UUID in the
warning is exactly `whisper.framework`'s Mach-O slice.)

Root cause: the manually-built `whisper.xcframework` (built by directly
invoking `clang++ -dynamiclib` against static libs compiled without an
Xcode-standard debug-info configuration) never had a dSYM generated for it
at all — confirmed directly: `dsymutil` on the original binary emitted
`warning: no debug symbols in executable`.

- Rebuilt whisper.cpp's macOS static libraries with
  `cmake --build build-macos --config RelWithDebInfo` (previously built with
  `Release`, which the CMake-generated Xcode project builds with debugging
  symbols disabled) — confirmed via `dwarfdump --debug-info` that the
  resulting binary has real DWARF, not just a symbol table (31 compile
  units).
- Re-linked `whisper.framework`'s dylib from the new libs (same
  `-force_load`/framework-link recipe as the original build), generated its
  dSYM with `dsymutil`, and recreated the xcframework via `xcodebuild
  -create-xcframework -debug-symbols <dSYM> ...` so the dSYM travels
  alongside the framework slice as Apple's documented mechanism for
  exactly this case.
- **Verified for real, not just by inspection**: ran the actual
  `./scripts/archive.sh` end-to-end (`xcodebuild ... archive`, Release
  config) and confirmed `whisper.dSYM` now appears in the produced
  `.xcarchive`'s `dSYMs/` folder alongside `Clio.app.dSYM`, with
  `dwarfdump --uuid` confirming an exact UUID match against the framework
  binary actually embedded in the archived `Clio.app` — the precise pair
  App Store Connect's symbol-upload check verifies.

### Fixed — Real crash-on-quit: `GGML_ASSERT([rsets->data count] == 0)` abort during normal app termination

Diagnosed directly from a live user debug log — the crash happened via
`-[NSApplication terminate:]` → `exit()`, the **normal** quit flow, not a
forced kill, meaning it would recur on every quit after whisper.cpp loaded
a model in that session. Root cause confirmed in whisper.cpp's own source
(`ggml-metal-device.m:952`, `ggml_metal_rsets_free`), whose own comment
reads *"if you hit this assert, most likely you haven't deallocated all
Metal resources before exiting"* — `WhisperCppEngine` cached
`whisper_context` pointers for the app's entire lifetime and never called
`whisper_free()` on them (confirmed via grep — zero matches).

- New `WhisperCppEngine.shutdown()` — frees every cached context via
  `whisper_free(ctx)`, clears the cache. Idempotent.
- New `AppDelegate.applicationShouldTerminate(_:)` (was missing entirely) —
  returns `.terminateLater`, runs the async shutdown, then
  `NSApp.reply(toApplicationShouldTerminate: true)` — the standard macOS
  pattern for async cleanup before quit.
- **Verified with a real, direct reproduction**, not just reasoning:
  compiled a standalone Swift test linking the actual `whisper.xcframework`,
  initialized a real context against the real bundled model. Without
  calling `whisper_free` first, the exact same assert and crash backtrace
  reproduced (`Abort trap: 6`, same `ggml_metal_device_free` →
  `vector<unique_ptr<ggml_metal_device>>` destructor chain as the user's
  report). With `whisper_free` called first (exactly what `shutdown()`
  now does), the process exited cleanly with code 0 — the fix is directly
  confirmed to eliminate the crash, not just theorized to.

### Fixed — Stereo transcription progress indicator frozen at 0% for the entire pipeline ("transcription isn't stopping")

A live user report ("transcription isn't stopping") turned out to be a
missing-feedback bug, not a hang. Investigated with real benchmarks against
the user's own real ~35-minute RØDE dual-channel interview recording
(found via its converted WAV files still present in the sandboxed
container's tmp directory):

- Ran the **full 35-minute file** through `whisper-cli` with the real
  production model at real beam-search width 5 (the app's default accuracy
  level) — completed in **4m10s**, ~8.5x faster than real-time. whisper.cpp
  itself is not the bottleneck.
- Checked real segment content-density against `isSuspectSegment`'s
  repair-trigger threshold using an actual transcript excerpt — every real
  segment scored far above the threshold, ruling out runaway
  false-positive repair fan-out as the cause.
- Read `repairTimelineGaps`/`repairMutualTimelineGaps`/`recoverGap` in
  full — all loops are bounded over finite, pre-computed lists; no
  recursion or unbounded retry found.
- **Actual root cause**: `runStereoTranscription` — the path used for any
  RØDE dual-channel recording — never touched `self.progress`/`self.stage`
  anywhere in its ~200 lines (confirmed via grep), unlike the mono path
  (`runNative`) which does. `TranscriptionRunner` mirrors this service's
  `$progress` publisher straight into the library UI, so the indicator sat
  frozen at its initial 0% for the entire pipeline — which, for a real
  35-minute interview (main pass ~8-9 min for both channels serialized
  through the `WhisperCppEngine` actor, plus repair/analysis overhead), can
  legitimately run 10-20+ minutes. A frozen 0% for that long reasonably
  reads as "stuck" even though real, correct work is happening the whole
  time.
- Added real `self.progress`/`self.stage` updates at every meaningful stage
  of `runStereoTranscription` (after split, after both channels' main
  decode, after cross-talk tighten/dedup, across mutual-gap and
  unclear-segment repair, at completion) — mirroring the granularity
  `runNative` already had, extended to the stereo path where it was missed
  when that orchestrator was originally built. Also fixed the same gap in
  the merged-channels fallback branch, which returned early without ever
  reaching the (previously nonexistent) final progress update either.

### Fixed — App bundle bloated to 8.3GB by now-unused WhisperKit CoreML models

User reported the app grew ~5GB. Traced precisely: 7.8GB of the 8.3GB
Debug build was transcription model weights — 5.8GB from WhisperKit's
CoreML models (both the clean and verbatim variants; the verbatim one was
converted earlier this session) plus 2.0GB from the new whisper.cpp GGML
models. Since `TranscriptionService` now calls `WhisperCppEngine`
exclusively, the entire 5.8GB `WhisperKitModels` chunk was dead weight —
not used by the live pipeline at all. The observed ~5GB growth lines up
almost exactly with (verbatim WhisperKit CoreML conversion, +2.9GB) +
(new whisper.cpp GGML models, +2.0GB) from earlier and later in this same
session.

- Removed `WhisperKitModels` from the "Link Model Resources"
  `PBXShellScriptBuildPhase`'s `inputPaths`/`outputPaths`/`clone_or_copy`
  calls in `Clio.xcodeproj/project.pbxproj`, and added an explicit
  `rm -rf` of any stale copy from a prior build's `DerivedData` (since
  removing it as a declared build-phase output means Xcode no longer
  manages/cleans it automatically). `NativeTranscriptionEngine.swift` and
  the WhisperKit SPM dependency are deliberately left in the tree as an
  inert fallback — this is a build-config change only, fully reversible,
  not a removal of the WhisperKit code path.
- **Verified for real**: ran a full `xcodebuild` and confirmed
  `Contents/Resources/` no longer contains `WhisperKitModels` in the built
  app, and total built app size dropped from **8.3GB to 2.5GB** — a bigger
  reduction than the growth the user observed, so the app is now smaller
  than before this session's whisper.cpp work despite the two new bundled
  GGML checkpoints.

- **Chromeless SVG splash screen** — Clio now opens with a full-opacity, borderless NSWindow splash
  displaying the approved brand graphic (`SplashBackground.svg`). The splash is driven entirely by
  the existing `StartupCoordinator` / `DependencyManager` startup sequence; no new startup logic
  was introduced.
  - Animated loading dots (`. → .. → ...`) cycle at 450 ms while startup checks run
  - Single crossfading status line in Norwegian updates live through all 12 startup steps
  - Version number (`v1.4.1`) shown bottom-right in monospaced type
  - Window has no title bar, traffic lights, or resize handle; rounded corners with macOS drop shadow

### Changed

- **Startup dwell times increased** for readability: system checks 900 ms (was 400 ms), dependency
  steps 800 ms (was 350 ms), `allClear` pause 1 s (was 600 ms)
- **Nav panel** — removed legacy ARM waveform logo from the top of the left-side navigation panel;
  menu items moved up to fill the space
- **Library hover states** — `BibliotekRow` now shows a subtle accent-tinted highlight on hover
  (6 % opacity); play button icon scales up 12 % and brightens on pointer entry
- **Pill buttons hover states** — `PillButtonStyle` ("Åpne", "Transkriber") now scales to 1.03× on
  hover with a brightness boost (+8 %), and 0.96× scale on press; 120 ms easing throughout
- **Final splash status message** changed from "Audio Recording Manager er klar" to "Klar"

### Fixed

- **SVG full opacity** — removed `mask-type:alpha` from `SplashBackground.svg`; macOS was
  interpreting the purple gradient luminance as alpha, causing the image to appear washed out
- **Window opacity on launch** — added `animationBehavior = .none`, `alphaValue = 1.0`, and
  `isRestorable = false` to the splash `NSWindow` to prevent macOS's default fade-in animation
  and session-restoration ghosting
- **Multiple splash windows** — `splashShown` guard in `AppDelegate` prevents duplicate splash
  windows from stacking on hot reload
- **`mainWindows()` filter** — now uses identity comparison (`$0 !== splashController.window`)
  instead of unreliable `.level == .normal` check
- **`AudioSourceSelector` compiler timeout** — extracted `AudioDeviceRow` struct to break up a
  `@ViewBuilder` closure that caused `the compiler is unable to type-check this expression` on SPM
  builds

---

## [1.4.0] - 2026-03-11

### Changed
- **Upgraded no-anonymizer from v0.4.0 to v0.5.0** — NER backend replaced with HuggingFace BERT
  - Removed SpaCy dependency (`nb_core_news_lg`) entirely; install is now `pip install "no-anonymizer[ner]"`
  - BERT model is downloaded automatically from HuggingFace on first use — no separate download step
  - Removed exit code 2 / `spaCyModelMissing` error path from bridge script and Swift service
  - Updated error messages and UI to reflect new install instructions
- **Migrated from NAV Design System to Liquid Glass design** ✅ IMPLEMENTED
  - Removed NAV Aksel design system (NAVColors, NAVSpacing, NAVRadius)
  - Introduced modern AppColors, AppSpacing, AppRadius using system colors
  - All UI components now use native macOS materials (.regularMaterial, .ultraThinMaterial, .thinMaterial)
  - System colors adapt automatically to light/dark mode

- **Modal windows and dialogs upgraded with Liquid Glass effects** ✅ IMPLEMENTED
  - NewFolderDialog: Added `.glassEffect(.regular)` with rounded corners
  - AnonymizationReminderDialog: Glass background with `.ultraThinMaterial` checklist
  - RecordingNameDialog: Glass effect with material-based preview section
  - All dialogs use modern `.borderedProminent` and `.bordered` button styles

- **Enhanced sheet presentations with presentation detents** ✅ IMPLEMENTED
  - SD Card Import: `.presentationDetents([.medium, .large])` with drag indicator
  - About View: `.presentationDetents([.large])`
  - New Folder Dialog: `.presentationDetents([.height(250)])` for compact size
  - Anonymization Dialog: `.presentationDetents([.height(400)])`

- **Button styles modernized with interactive glass effects** ✅ IMPLEMENTED
  - Replaced NAVPrimaryButtonStyle with GlassButtonStyle
  - Interactive glass effects respond to hover states
  - Smooth animations with `.thinMaterial` on hover/press
  - All buttons use AppColors.accent for consistent theming

- **UI components updated to system design language** ✅ IMPLEMENTED
  - NavPanel: System colors with glass-effect selection states
  - RecordingRowView: Modern selection highlighting with AppColors.accentSubtle
  - RecordingPlayerPanel: Accent colors for play button and progress indicators
  - SidebarMenuItem: Glass hover effects with `.ultraThinMaterial`
  - SD Card Detection Banner: Success color (green) with glass-style backgrounds
  - Recording buttons: Destructive color (red) for stop, glass effects for start

### Added
- **ContentView wrapper for proper app initialization** ✅ IMPLEMENTED
  - Added ContentView as entry point wrapping MainView
  - Window style changed to `.hiddenTitleBar` for modern macOS look
  - Default window size set to 1200x900 with 700x800 minimum
  - Full-screen content with `.ignoresSafeArea()`

### Fixed
- **App launch issue resolved** ✅ IMPLEMENTED
  - Fixed missing ContentView causing app not to display
  - Proper window configuration ensures visible launch
  - Window sizing constraints prevent too-small windows

### Design Philosophy
- **Native macOS Integration**: Uses system materials, colors, and styles for automatic light/dark mode adaptation
- **Liquid Glass Throughout**: Interactive glass effects provide depth, polish, and premium feel
- **Accessibility First**: Better contrast with system colors, proper semantic colors (destructive, success, warning)
- **Modern Presentation**: Smart sheet sizing with drag indicators and appropriate detents
- **Interactive Feedback**: Hover states, glass effects, and smooth animations enhance user experience

---

## [1.3.1] - 2026-03-06

### Added
- **Anonymization confirmation modal** (`AnonymizationModal.swift`): A consent gate shown before every anonymization run
  - Lists what is automatically identified (names, phone numbers, national ID numbers, email addresses)
  - Lists what is NOT automatically caught (indirect identifiers, nicknames, small-community geography, incomplete data)
  - Warning banner emphasising that automatic anonymization is not sufficient alone
  - Checkbox acknowledgement: "Jeg forstår at teksten må kontrolleres manuelt"
  - "Fortsett med anonymisering" button disabled until checkbox is ticked
  - Applies to all three trigger points: initial run, re-run, and retry after error

### Changed
- **Anonymization section moved above transcript text** in both `RecordingDetailView` and `TranscriptsView` — buttons are now at the top of the panel

---

## [1.3.0] - 2026-03-04

### Added
- **Transkripsjoner tab**: New top-level tab alongside "Lydopptak" for browsing and managing transcript files
  - Reads `.txt` files from `~/Desktop/tekstfiler/` (user-agnostic path, works for any user)
  - Two-panel layout: file list on the left, transcript content + anonymization on the right
  - Folder is created automatically on first launch
  - File watching via DispatchSource (live updates when files are added/removed)
- **Anonymization service** (`AnonymizationService.swift`): calls the `no-anonymizer` Python library via subprocess
  - Locates `anonymize_bridge.py` in the app bundle Resources
  - 30-second timeout with graceful cancellation
  - Login-shell subprocess (`/bin/sh -lc`) so Homebrew/pyenv/conda `python3` is on PATH
- **Anonymization UI** (states A–D) in both transcript detail and recording detail:
  - State A: "Anonymiser transkripsjon" button with explanation of what is removed
  - State B: progress indicator with cancel button
  - State C: completion date, redaction stats, toggle between original / anonymised text
  - State D: clear error message; SpaCy model missing shows exact install command
- **Recording metadata persistence** (`RecordingMetadataManager.swift`): side-car `.metadata.json` files alongside audio/transcript files
  - `originalTranscript` is immutable after first write (cannot be overwritten)
  - `anonymizedTranscript`, `anonymizationDate`, `anonymizationStats` updated per anonymization run
- **Audit log** (`AuditLogger.swift`): append-only JSONL at `~/Desktop/lydfiler/.audit_log.jsonl`
  - Records timestamp, recording/transcript ID, redaction counts per category, processing time, outcome
  - Never logs actual text content — counts and metadata only
- **Filename-based linking**: transcript files auto-linked to recordings with matching stem
  - e.g. `intervju_20260304.txt` ↔ `intervju_20260304.m4a`
  - Linked recording shown in transcript detail with "Åpne lydopptak" button
- **`anonymize_bridge.py`** bundled in `Resources/`: Python bridge script with structured exit codes
  - Exit 0: success; 2: SpaCy model missing; 3: library not installed

### Changed
- **MainView** now has a tab bar ("Lydopptak" / "Transkripsjoner") below the native toolbar
- Toolbar sidebar/folder buttons only visible on the Lydopptak tab
- `~/Desktop/tekstfiler/` path uses `FileManager.default.urls(for: .desktopDirectory)` — no hardcoded username

---

## [1.2.0] - 2025-12-15

### Added
- **Recording naming dialog**: Name recordings before saving with auto-timestamp appended
  - Format: `[custom name]_YYYYMMDD_HHMMSS.m4a`
  - Live filename preview
  - Auto-focus text field, Enter to save
  - Option to discard recording
- **Audio duration display**: List items now show recording duration instead of file size
  - Duration calculated from audio track metadata
  - Format: `M:SS` (e.g., "2:34")

### Changed
- **Play button styling**: Now uses IconButton component (grey circle) matching other action buttons

### Fixed
- Removed unused `startIndex` variable warning in ScrollingWaveformView

---

## [1.1.0] - 2025-12-03

### Added
- feat(release): Add automated versioning and CI/CD release workflow
- docs(adr): Add 13 Architecture Decision Records for Agentive Starter Kit
- feat(arm-0001): Set up TDD infrastructure for Swift macOS app
- feat: Import Audio Recording Manager codebase from virgin-project
- docs: Add comprehensive Linear sync onboarding checklist
- feat(linear): Robust multi-team support with KEY resolution
- feat(linear): Add Linear sync infrastructure (ASK-0005)
- feat: Implement ASK-0001 through ASK-0004 from AL2 feedback
- feat(tasks): Add ASK-0001 through ASK-0004 from AL2 feedback
- feat(serena): Update agent files and add ADR-0002
- feat: Enhance TDD seed task template v3.0 with AL2 improvements
- docs: Add session handover for 2025-11-27
- feat: Add TDD seed task to onboarding flow
- docs: Add "Pulling Updates from Starter Kit" section to README
- feat: Enable model specifications by default
- feat: Add model recommendations for all agents
- feat(onboarding): Add Phase 7 for GitHub repository setup
- docs: Add detailed Linear Integration section to README
- feat(onboarding): Suggest folder name as project name
- feat: Improve onboarding flow with preflight checks and clearer docs
- docs: Add session handover for rem continuity
- feat(serena): Add Serena MCP installation and configuration
- feat: Separate onboarding into dedicated agent, add ADR-0001
- Revert "refactor: Move launcher to scripts/, add ADR-0001"
- refactor: Move launcher to scripts/, add ADR-0001
- feat(onboarding): Add first-run onboarding flow with context injection
- feat: Initial release of Agentive Starter Kit v1.0.0

### Changed
- docs(pyproject): Improve tool.setuptools comment clarity
- improve(pyproject): Incorporate AL2 adaptations
- refactor: Replace 'Coordinator' with 'Planner' in adversarial docs
- docs: Update session handover with seed task v2.0 changes
- refactor: Document hardcoded arrays in launch script
- refactor: Remove redundant coordinator agent
- refactor: Rename rem agent to planner for clarity

### Fixed
- fix(swiftui): Update deprecated onChange to new macOS 14.0+ API
- fix(linear-sync): Gracefully skip when API key not configured
- fix(swiftlint): Disable rules incompatible with legacy code
- fix(onboarding): Update agent files with project name for Serena activation
- fix(serena): Use user scope for global MCP availability
- fix: Correct model IDs in all agent files
- fix: Strip YAML comments from model name in launcher
- fix: Improve TDD seed task based on agentive-lotion-2 feedback
- fix: Exclude TASK-STARTER-TEMPLATE.md from agent launcher
- fix: Remove embedded YAML template from onboarding.md
- fix(serena): Improve setup flow and handle browser popup issue
---

## [Unreleased]

### In Progress
- Phase 0 file storage migration (see ADR-1014)

### Changed - 2025-11-27
- **Migrated to NavigationSplitView architecture** ✅ IMPLEMENTED
  - Replaced custom sidebar implementation with native NavigationSplitView
  - Improved sidebar toggle animation and column visibility management
  - Added flexible sidebar width (min: 250pt, ideal: 300pt, max: 400pt)
  - Fixed rendering artifacts during sidebar animations
  - Removed duplicate toggle buttons (using native split view controls)

- **Updated deployment target to macOS 15.0+ (Sequoia)** ✅ IMPLEMENTED
  - Updated LSMinimumSystemVersion in Info.plist to 15.0
  - Added `-target arm64-apple-macos15.0` to build configuration
  - Ensures compatibility with latest SwiftUI features and APIs
  - Better animation performance and rendering with Sequoia SDK

- **UI/UX improvements** ✅ IMPLEMENTED
  - Applied white background theme across all views
  - Removed toolbar separator line for cleaner appearance
  - Fixed double-animation issues in content area
  - Improved overall visual consistency

### Fixed - 2025-11-24
- **Fixed false positive SD card detection - PKG/DMG installers no longer detected** ✅ TESTED
  - Issue: All mounted volumes (PKG installers, DMG files) were incorrectly detected as SD cards
  - Root cause: Insufficient filtering allowed disk images to pass validation
  - **Solution implemented:**
    - Added read-only volume check (installers are typically read-only)
    - Added BSD name pattern matching (disk images: `disk6`, real media: `disk2s1`)
    - Added diskutil verification to query if volume is a disk image
    - Expanded installer keyword list: "wacom", "driver", "pkg"
    - Added write-protect check via `kDADiskDescriptionMediaWritableKey`
  - **Now correctly ignores:** DSSPlayerV778, WacomTablet, all PKG/DMG installers
  - **Verified working:** No false positives with multiple disk images mounted

### Fixed - 2025-11-16
- **Fixed SD card detection to properly distinguish between disk images and real media** ✅ TESTED
  - Issue #1: DMG files (like "DSSPlayerV778" installer) were incorrectly detected as SD cards
  - Issue #2: Built-in SD card readers were rejected because macOS marks them as "internal"
  - Solution: Validate removable + local, but allow internal SD card readers
  - DiskArbitration callbacks check device protocol to exclude "Disk Image" and "Virtual Interface"
  - Added keyword filtering to skip installer/setup volumes ("installer", "dmg", "player", etc.)
  - Expanded system volume exclusion list (Preboot, Recovery, VM, Update, Data)
  - **Now correctly detects:** SD cards (internal/external readers) and USB drives
  - **Now correctly ignores:** DMG files, disk images, system volumes, installers
  - **Verified working:** Detects real SD cards while ignoring DSSPlayerV778 installer DMG

### Added - 2025-11-16
- **SD card eject functionality** ✅ TESTED
  - Added "Eject" button to SD card detection banner on main view
  - Added "Eject" button to SD Card Import sheet window
  - Uses `diskutil eject` command to safely unmount SD card
  - Button replaces progress indicator when not scanning files
  - **Verified working:** Successfully ejects SD cards from both locations

### Documentation Updates - 2025-11-16
- Created BACKLOG.md for project management and feature planning
- Added Technologies & Credits section to README documenting JOJO Transcribe tech stack
- Documented PM model usage guidelines (use Haiku for documentation tasks)
- Added Phase 6: UI/UX Design Review with NAV Design System alignment

---

## [0.2.0] - 2025-01-16

### Added - Phase 2: Recording Workflow
- Voice Memos integration - automatic launch on "Record with Voice Recorder" button
- Timestamped file naming: `lydfil_YYYYMMDD_HHMMSS.m4a`
- Automatic file storage to `~/Desktop/lydfiler` directory
- "Upload to Teams" button with automatic network enable/disable
- Manual network override controls (Enable/Disable Network buttons)
- Visual network status indicators for WiFi and Bluetooth state

### Changed
- Enhanced UI with large, researcher-friendly buttons
- Improved network control workflow for upload operations

---

## [0.1.0] - 2025-01-15

### Added - Phase 1: Core Security & UI
- Auto-launch on Mac startup capability (via LaunchAgent)
- Automatic network isolation on app launch (WiFi, Bluetooth, AirDrop disabled)
- macOS native app built with Swift 6.1+ and SwiftUI
- Basic UI framework with network control buttons
- Security-first architecture for zero-trust environments
- Integration with VG JOJO Transcribe app

### Security
- Network isolation as default state
- Administrator privileges required for network/Bluetooth control
- Designed for dedicated, single-purpose research computers

---

## Project Information

### Maintained By
Project Manager: Claude Code

### Documentation Standards
- **Format**: High-level summaries of features and changes
- **Updates**: After each feature implementation or significant change
- **Version**: Semantic versioning (MAJOR.MINOR.PATCH)

### Categories Used
- **Added**: New features
- **Changed**: Changes to existing functionality
- **Deprecated**: Soon-to-be removed features
- **Removed**: Removed features
- **Fixed**: Bug fixes
- **Security**: Security-related changes
