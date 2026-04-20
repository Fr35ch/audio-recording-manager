# Recording Detail View — Implementation Guide

**Epic:** Audio Recording
**User stories:** [US-R8–US-R12](USER_STORIES.md)
**Status:** Draft — ready for implementation
**Date:** 2026-04-17
**Related:**
- [TRANSCRIPT_EDITOR.md](../transcription/TRANSCRIPT_EDITOR.md) — the view this detail view navigates *into*
- [US-T11](../transcription/USER_STORIES.md#us-t11) — transcript editor story
- [ADR-1014](../decisions/adr/ADR-1014-file-storage-architecture-pivot.md) — storage layout

---

## Purpose of this document

This document specifies the redesigned `RecordingDetailView` — the panel that opens when a researcher selects a recording from the recordings list. It documents what changes from the current implementation, why each change was made, and what the target state looks like. It is prescriptive about *what* to build and deliberately silent about Swift syntax.

Read [CLAUDE.md](../../../CLAUDE.md) first. This document assumes familiarity with the design token system, the Norwegian-in-UI rule, and the Phase 0 storage layout.

---

## Why this view needs a redesign

The current `RecordingDetailView` (see [`RecordingDetailView.swift`](../../../Sources/AudioRecordingManager/RecordingDetailView.swift)) has accumulated several problems:

**1. Duplicate transcription UI (the main problem).** When transcription completes, the researcher can tap «Vis segmenter», which opens `transcriptionResultSheet` — a bespoke modal sheet showing a read-only `TranscriptionResultView`. This is a completely different UI from the `TranscriptEditorView` that opens when the researcher selects the same transcript from the Transkripsjoner tab. Two different surfaces for the same data creates confusion, forces double maintenance, and gives researchers a worse experience (the modal is read-only; the editor supports editing, playback sync, and anonymization).

**2. «Analyse» belongs to the transcript, not the recording.** Analysis runs on the transcript text, not the audio. Having it in the recording detail view creates a false mental model and couples two distinct workflow steps unnecessarily. Researchers edit → anonymize → analyse as a transcript-level flow; the recording detail view should stay focused on the recording itself.

**3. «Vis i finder» is noise.** Researchers work on shared library machines where file system navigation is neither expected nor appropriate. The button surfaces implementation details and adds no workflow value. Remove it.

**4. Taleutskilling (diarization) is not yet functional.** The button exists but does not work. It should remain in the UI as a placeholder to signal the planned capability, but with a clear «ikke tilgjengelig ennå» state so researchers know it is coming rather than assuming the button is broken.

---

## Scope

### In scope (this redesign)

- Removing the `transcriptionResultSheet` modal and replacing the «Vis segmenter» / «Vis transkripsjon» button with a navigation action that opens `TranscriptEditorView`
- Removing «Vis i finder» from the UI entirely
- Removing «Analyse» from this view (it stays in `TranscriptEditorView` / the transcription section — see US-T12 and the Anonymisering section in the transcript editor)
- Adding a clear disabled / «ikke tilgjengelig» state for diarization (taleutskilling)
- Keeping the playback section, transcription section, and filinformasjon section

### Out of scope (unchanged or deferred)

- The recording list itself (handled by the recordings tab in `main.swift`)
- How recordings are created or stored (see ADR-1014)
- The transcription engine, settings, or model selection — those live in `TranscriptionSettingsView.swift`
- The anonymization flow — it now lives in `TranscriptEditorView` (US-T12); this view no longer initiates anonymization
- The paste-in manual transcript area — keep it as-is for now; it is a minor convenience for edge cases

---

## Target layout

```
┌─────────────────────────────────────────┐
│  Header (filename + icon)               │
├─────────────────────────────────────────┤
│  Avspilling                             │
│  ┌───────────────────────────────────┐  │
│  │ ◀◀  ▶  scrubber  0:00 / 12:34   │  │
│  └───────────────────────────────────┘  │
├─────────────────────────────────────────┤
│  Transkripsjon                          │
│  ┌───────────────────────────────────┐  │
│  │  [state: notStarted]              │  │
│  │  «Transkriber lydfil automatisk»  │  │
│  │  Modell: large  ·  2 talere       │  │
│  │                                   │  │
│  │  [state: inProgress]              │  │
│  │  ⟳ Laster modell...  [Avbryt]    │  │
│  │                                   │  │
│  │  [state: completed]               │  │
│  │  ✓ Ferdig · 42 segmenter          │  │
│  │  «Åpne i transkripsjonseditoren»  │  │
│  │  «Kjør på nytt»                   │  │
│  │                                   │  │
│  │  [state: failed]                  │  │
│  │  ⚠ Feil · «Prøv igjen»           │  │
│  └───────────────────────────────────┘  │
│  ┌───────────────────────────────────┐  │
│  │  Taleutskilling   (ikke tilgj.)   │  │
│  │  Identifiser hvem som snakker     │  │
│  │  [Kjør taleutskilling — deaktivert│  │
│  │   med tooltip: kommer i v2.x]     │  │
│  └───────────────────────────────────┘  │
├─────────────────────────────────────────┤
│  Filinformasjon                         │
│  Filnavn / Dato / Varighet / Størrelse  │
└─────────────────────────────────────────┘
```

The anonymization section that currently lives in this view is **removed**. Anonymization is initiated from the transcript editor (US-T12).

---

## Section-by-section specification

### Header

Unchanged from current. Shows the recording filename and the `waveform.and.mic` icon.

### Avspilling (playback)

Unchanged from current implementation:
- Restart button (backward.end.fill)
- Play/pause toggle (46pt icon, accent colored)
- Scrubber with time labels
- Keyboard shortcut space = play/pause

No changes needed here.

### Transkripsjon section

The section is a state machine with four states. The state machine is identical to the current one except the `completed` state is redesigned.

**State: notStarted**

Same as today. Shows:
- «Transkriber lydfil automatisk» primary button
- Current model and speaker count summary (read-only — settings are in the settings panel)
- Warning label if `no-transcribe` is not installed

**State: inProgress**

Same as today. Shows:
- Spinner + current stage label (animated, sourced from `transcriptionService.stage.displayName`)
- Determinate progress bar once `transcriptionService.progress > 0`
- «NB-Whisper-modellen lastes ved første kjøring» note
- «Avbryt» button

**State: completed** ← *this is where the redesign matters*

Remove: the «Vis segmenter» button that opened `transcriptionResultSheet`.

Add: an «Åpne i transkripsjonseditoren» primary button. Tapping it invokes the `onNavigateToTranscript` callback (see [Navigation pattern](#navigation-pattern) below). The parent view handles the actual navigation — this view just signals intent.

Keep: the metadata summary (segment count, speaker count, duration) and the «Kjør på nytt» secondary button.

Do not open any sheet or modal from this button. Do not re-implement `TranscriptionResultView` inline.

**State: failed**

Unchanged. Shows error description and «Prøv igjen» button.

### Taleutskilling (diarization) section

Show this section always (not gated on transcript existence). It is a separate capability from transcription.

Display:
- Section label «Taleutskilling»
- One-line description: «Identifiser hvem som snakker i opptaket»
- A single «Kjør taleutskilling» button — **disabled**, with a `.help(...)` tooltip: «Taleutskilling kommer i en fremtidig versjon av ARM»
- Do **not** show an error state or spinner — this feature is simply not available yet

The button should be visually present but clearly inactive. This communicates intent and prevents researchers from thinking the button was accidentally omitted.

> **Note for implementer:** When diarization is eventually wired up, this section's enabled state should be gated on `transcriptionService.isInstalled` (same guard as the transcription button) *and* a HuggingFace token being configured in settings (see US-T6 in the transcription user stories). Don't add that logic now — just leave the disabled placeholder.

### Filinformasjon section

Unchanged from current. Shows:
- Filnavn
- Dato
- Varighet
- Størrelse

### Removed sections

| Section | Disposition |
|---------|-------------|
| `anonymizationSection` | Removed. Anonymization is now initiated from `TranscriptEditorView` (US-T12). |
| `transcriptSection` (toggle original/anonymized) | Removed. Viewing transcript text is the transcript editor's job. |
| `transcriptionResultSheet` modal | Removed. Replaced by `onNavigateToTranscript` callback. |
| «Vis i finder» button | Removed. No replacement. |
| «Analyse» button | Removed from this view. Lives in the transcript editor. |

The paste-in manual transcript area (`transcriptInputArea`) may be kept as a low-priority fallback but should not be a prominent part of the layout.

---

## Navigation pattern

`RecordingDetailView` accepts an optional callback:

```
onNavigateToTranscript: ((UUID) -> Void)?
```

When the researcher taps «Åpne i transkripsjonseditoren», this callback is invoked with the recording's UUID. The parent view (the recordings tab in `main.swift` or wherever the sheet is presented) is responsible for:

1. Dismissing the recording detail sheet
2. Switching the app to the Transkripsjoner tab
3. Selecting the transcript that corresponds to this recording UUID

This is the same delegation pattern already used in `TranscriptDetailPanel`, which accepts `onSwitchToRecordings: () -> Void` as a callback. Consistent — don't invent a different pattern.

If `onNavigateToTranscript` is `nil` (e.g., in a preview), the button should still be visible but tapping it is a no-op.

---

## What is *not* changing

- The transcription engine (`TranscriptionService.swift`) — no changes
- The playback controls — no changes
- The `TranscriptionModel`, `defaultSpeakers`, `verbatim`, `language` `@AppStorage` keys — no changes
- The file info section — no changes
- The state machine enum names (`TranscriptionUIState`) — no changes unless the implementing agent has a reason

---

## Design decisions

**Replace the modal with navigation to `TranscriptEditorView`.**
*Why:* The modal opened a read-only `TranscriptionResultView` — a completely different UI surface from the `TranscriptEditorView` available in the Transkripsjoner tab. Researchers who discovered the editor from the tab could not get to it from the recording detail view, and vice versa. Duplicate UIs for the same data are a maintenance burden and a UX inconsistency. The fix is to remove the modal entirely and route «Vis transkripsjon» through the same navigation path as the Transkripsjoner tab.
*How to apply:* The `transcriptionResultSheet` computed property and the `showTranscriptionResult: Bool` state variable should be deleted. The «Vis segmenter» button label should change to «Åpne i transkripsjonseditoren». Wiring is done via the `onNavigateToTranscript` callback.

**Move «Analyse» out of this view.**
*Why:* LLM analysis runs on the transcript text. Placing it in the recording detail view implies the recording is its input, which is misleading. Analysis belongs in the transcript editor's action surface, where the researcher can see the transcript and trigger analysis in context.
*How to apply:* Remove any «Analyse»-related buttons, state variables, and sections from `RecordingDetailView`. Do not add them elsewhere without a corresponding user story.

**Remove «Vis i finder».**
*Why:* Researchers work on shared library machines under FileVault. Exposing the file system via Finder undermines the app's role as the single interface for managing interview data. The feature adds no workflow value in the target environment.
*How to apply:* Delete the button and any `NSWorkspace.shared.activateFileViewerSelecting` calls from this view.

**Diarization stays as a visible disabled placeholder.**
*Why:* Hiding the button entirely would leave researchers unaware the feature is planned, which could drive them to seek external tools unnecessarily. A clearly disabled button with a tooltip sets expectations correctly without implying it is broken.
*How to apply:* Render the button with `.disabled(true)` and a `.help(...)` tooltip. No spinner, no progress state, no error state. The full diarization implementation is tracked under US-T6.

**Anonymization section removed from this view.**
*Why:* Anonymization in the current view operates on the raw transcript text. Moving it to `TranscriptEditorView` (US-T12) keeps all transcript-level actions in one place and gives the researcher context (they can see what they're anonymizing). The recording detail view's job is to play the recording and trigger transcription — not to be a full transcript processing pipeline.
*How to apply:* Delete `anonymizationSection`, `stateA`–`stateD`, `anonymizationState`, `showAnonymizationModal`, `anonymizationTask`, `startTime`, `startAnonymization()`, `cancelAnonymization()`, the `whatIsRemoved` array, `statsSummary()`, `toggleButton()`, and the import of `AnonymizationService` from this file. Verify nothing else in the file references them before deleting.

---

## Acceptance

This redesign is done when:

- [ ] US-R8 acceptance criteria are met (playback, see USER_STORIES.md)
- [ ] US-R9 acceptance criteria are met (transcription from detail view)
- [ ] US-R10 acceptance criteria are met (navigation to TranscriptEditorView, no modal)
- [ ] US-R11 acceptance criteria are met (diarization placeholder)
- [ ] US-R12 acceptance criteria are met (filinformasjon)
- [ ] `transcriptionResultSheet`, `showTranscriptionResult`, and all related state are deleted
- [ ] `anonymizationSection`, anonymization state, and all related helpers are deleted from this file
- [ ] «Vis i finder» is removed
- [ ] No hardcoded colours, spacing, or radii — all tokens from `Design/DesignTokens.swift`
- [ ] All user-facing strings are Norwegian Bokmål
- [ ] CHANGELOG.md has an entry under the next minor version
