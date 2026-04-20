# Phase 0 Build Tasks — File Management & Teams Sync

**Epic:** File Management & Teams Sync
**Phase:** 0 of 2 — Safe Storage, Migration, and Return Machine
**Spec:** [FILE_MANAGEMENT_AND_TEAMS_SYNC.md](../../FILE_MANAGEMENT_AND_TEAMS_SYNC.md)
**Stories:** [USER_STORIES.md](USER_STORIES.md)
**Decision:** [ADR-1014](../../decisions/adr/ADR-1014-file-storage-architecture-pivot.md)
**Date:** 2026-04-14
**Status:** Ready to start

---

## Scope

Phase 0 delivers the storage pivot end-to-end **except** the actual OneDrive/Graph upload (that's Phase 1). Upload verification is stubbed behind a feature flag so the Return Machine flow is fully operational on its own.

**In scope:**
- New storage layout in `~/Library/Application Support/AudioRecordingManager/`
- UUID-named recording folders with metadata sidecars
- Audit log relocation and rotation
- Migration from legacy Desktop folders
- Rewiring the app to use the new store
- Removing all Desktop write paths
- Return Machine flow (pre-check, friction gate, secure delete, receipt)

**Not in scope (Phase 1 or later):**
- Microsoft Graph API upload
- Project concept in the UI
- Teams destination picker
- Hash-chained audit log

---

## Dependencies (external, kick off now)

| Dependency | Owner | Blocks | Status |
|------------|-------|--------|--------|
| MDM sync exclusion of ARM data path | mac-fleet admin | 0F ship gate | To request |
| FileVault mandate confirmation | NAV IT | 0F ship gate | To confirm |
| Azure AD / Entra ID app registration | NAV IT | Phase 1 (not Phase 0) | Request now, long lead time |

Phase 0 **can be built and tested locally** without any of these, but Phase 0F should not ship to researchers until MDM exclusion and FileVault are confirmed.

---

## Sequencing

0A → 0B → 0C can happen in parallel with the existing app running unchanged (new code, not yet wired). 0D integrates them one call site at a time. 0E is cleanup. 0F builds on 0D.

```
0A (storage foundation) ──┐
0B (audit logger move)   ──┼──► 0D (rewire) ──► 0E (cleanup) ──► 0F (return machine)
0C (migration)            ──┘
```

---

## 0A — Storage foundation

> **Goal:** A new storage layer built in isolation. Nothing wired up yet; proves the shape is right.

### A1. Define storage layout constants
- **File:** new `Sources/AudioRecordingManager/Storage/StorageLayout.swift`
- **API:** typed path helpers — `recordingsRoot`, `auditRoot`, `stateRoot`, `recordingFolder(id:)`, `audioURL(id:)`, `transcriptURL(id:)`, `metaURL(id:)`
- **Rule:** one source of truth for paths. No string concatenation elsewhere.
- **Done when:** unit test round-trips (build path → parse UUID back out)

### A2. Define `RecordingMeta` sidecar model
- **File:** new `Sources/AudioRecordingManager/Storage/RecordingMeta.swift`
- **Type:** `Codable` struct matching the sidecar schema in the spec
- **Include `schemaVersion` field** from day one
- **Done when:** encode→decode round-trips without loss; unknown fields on decode do not crash

### A3. Implement `RecordingStore` CRUD
- **File:** new `Sources/AudioRecordingManager/Storage/RecordingStore.swift`
- **API:** `create() -> RecordingHandle`, `loadAll() -> [RecordingMeta]`, `load(id:) -> RecordingMeta?`, `updateMeta(id:transform:)`, `delete(id:)`
- **Rules:**
  - All writes are atomic (`Data.write(to:options:.atomic)` or temp-file-then-rename).
  - `create()` mints UUID, creates folder, writes initial sidecar with `createdAt` and default `displayName = ISO date`.
  - `updateMeta` is read-modify-write under a per-recording serial queue so recording + transcription writers don't race.
- **Done when:** unit tests cover every method and concurrent `updateMeta` hammering produces consistent state

### A4. Audio integrity hash
- **API:** utility that computes SHA-256 over the audio file and writes it into the sidecar on recording finalize
- **Done when:** matches `shasum -a 256` on the same file

---

## 0B — Audit logger on the new path

### B1. Relocate `AuditLogger`
- **Change:** `AuditLogger` writes to `~/Library/Application Support/AudioRecordingManager/audit/audit-YYYY-MM.jsonl`
- **Remove:** writes to `<audio folder>/.audit_log.jsonl`
- **Done when:** existing callers work unchanged; new entries land in the new location

### B2. Define `AuditEvent` types
- **File:** add/extend whatever file hosts `AuditLogger`
- **Type:** enum with typed payload per case — `recordingCreated`, `recordingFinalized`, `transcriptCompleted`, `transcriptFailed`, `uploadQueued`, `uploadCompleted`, `uploadFailed`, `migrationCompleted`, `returnMachineStarted`, `returnMachineCompleted`, `wipeReceiptWritten`
- **Done when:** adding a new event type is a single-file change; payloads survive JSON round-trip

### B3. Monthly rotation
- **Rule:** opening the logger on the first write of a new month creates a new file; no background rotation
- **Done when:** advancing the clock by a month and writing produces a correctly-named new file

### B4. Defer: hash-chain
- Mark as `// TODO(audit-tamper)` in the logger. Not in Phase 0. Revisit after NAV compliance answer.

---

## 0C — Migration from legacy Desktop folders

### C1. `LegacyStorageScanner`
- **File:** new `Sources/AudioRecordingManager/Storage/LegacyStorageScanner.swift`
- **API:** reports existence + file counts of `~/Desktop/lydfiler/` and `~/Desktop/tekstfiler/`
- **Done when:** accurate counts; returns empty when folders absent; doesn't crash on permission errors

### C2. `StorageMigrator.migrate()`
- **File:** new `Sources/AudioRecordingManager/Storage/StorageMigrator.swift`
- **Behaviour:**
  - For each legacy `.m4a`: mint UUID, create recording folder, move audio as `audio.m4a`, write sidecar with `displayName = original stem` and `createdAt = file mtime`
  - For each legacy `.txt`: match to audio by stem, move as `transcript.txt` inside the same recording folder, update sidecar
  - Orphan transcripts get their own folder with `audio.status = missing`
  - Each migration emits an audit entry
- **Done when:** end-to-end test — seed temp Desktop with 3 audio + 3 matching transcripts + 1 orphan, run migration, verify 4 recording folders with correct pairing + 4 audit entries + empty Desktop folders

### C3. One-shot on first launch
- **Rule:** migration runs once, gated by `migrationCompletedAt` in `state/app.json`
- **Done when:** second launch does not touch Desktop; audit log has one migration entry

### C4. Post-migration confirmation UI
- **Rule:** one-time in-app message, "Moved N recordings to secure storage"
- **Not:** a decision prompt. Migration is mandatory.
- **Done when:** shown once, never again

### C5. Remove empty legacy folders, leave breadcrumb
- **Behaviour:** after successful migration, delete `~/Desktop/lydfiler/` and `~/Desktop/tekstfiler/` if empty; write `~/Desktop/ARM_moved_to_secure_storage.txt` with a human-readable note
- **Done when:** no empty `lydfiler` / `tekstfiler` survives on Desktop post-migration

---

## 0D — Rewire the app to use `RecordingStore`

> **Goal:** Biggest integration block. Touch many files. App stays runnable at every step — do not land in one commit.

### D1. Rewire `AudioRecorder` file-creation path
- **Change:** recorder calls `RecordingStore.create()` instead of `AudioFileManager.getNewFilePath()`; writes to UUID-based path; calls `store.finalize(id:duration:)` on stop
- **Done when:** creating a recording produces a proper folder with audio + populated sidecar; nothing lands on Desktop; `recordingCreated` + `recordingFinalized` audit entries emitted

### D2. Rewire transcription output
- **Change:** `TranscriptionService` writes into the recording's folder via the store; updates sidecar atomically through `store.updateMeta`
- **Done when:** transcription on a post-migration recording lands in the correct folder and flips `transcript.status` to `done`

### D3. Replace `RecordingsManager` enumeration
- **Change:** `loadRecordings()` builds `RecordingItem`s from `RecordingStore.loadAll()` using sidecar `displayName`
- **Done when:** Recordings tab shows the same list, labelled correctly, sorted by `createdAt`

### D4. Replace `TranscriptManager` enumeration
- **Change:** enumerate from `RecordingStore`; replace `DispatchSource` folder watch with a `NotificationCenter` signal emitted by the store on sidecar writes
- **Done when:** Transcripts tab updates within ~1s of a sidecar change; deleting a recording removes its transcript from the list

### D5. Rewire `recording.path` consumers
- **Change:** every `URL(fileURLWithPath: recording.path)` site uses `RecordingStore.audioURL(id:)` (or `transcriptURL(id:)`) instead
- **Known sites:** [main.swift](../../../Sources/AudioRecordingManager/main.swift), [RecordingDetailView.swift](../../../Sources/AudioRecordingManager/RecordingDetailView.swift), [TranscriptsView.swift](../../../Sources/AudioRecordingManager/TranscriptsView.swift), [RecordingMetadataManager.swift](../../../Sources/AudioRecordingManager/RecordingMetadataManager.swift)
- **Done when:** `rg 'URL\(fileURLWithPath: recording\.path' Sources/` returns zero matches outside the store

### D6. Retire `AudioFileManager`
- **Change:** delete the class; any still-useful logic (filename-generation timestamp format) moves into `RecordingStore`
- **Done when:** file deleted, app builds

---

## 0E — Remove Desktop egress

### E1. Strip `.desktopDirectory` usage
- **Known sites (from grep 2026-04-14):**
  - [main.swift:119](../../../Sources/AudioRecordingManager/main.swift#L119) — `AudioFileManager` (retired in D6)
  - [main.swift:2825](../../../Sources/AudioRecordingManager/main.swift#L2825)
  - [main.swift:3213](../../../Sources/AudioRecordingManager/main.swift#L3213)
  - [main.swift:3358](../../../Sources/AudioRecordingManager/main.swift#L3358)
  - [RecordingDetailView.swift:916](../../../Sources/AudioRecordingManager/RecordingDetailView.swift#L916)
  - [TranscriptManager.swift:48](../../../Sources/AudioRecordingManager/TranscriptManager.swift#L48)
- **Exception:** `LegacyStorageScanner` in 0C keeps its single `.desktopDirectory` reference
- **Done when:** `rg '\.desktopDirectory' Sources/` returns only the scanner

### E2. Remove "Reveal in Finder / Save to Desktop" UI actions
- **Change:** menu items, context menus, toolbar buttons that export or reveal files to Desktop are removed
- **Rationale:** compliance requirement, not a feature choice
- **Done when:** no UI path triggers a Desktop write

### E3. Remove share-sheet paths
- **Change:** strip any `NSSharingServicePicker` / `NSSharingService` usage for audio or transcripts
- **Done when:** `rg 'NSSharingService' Sources/` returns no matches in audio/transcript flow

---

## 0F — Return Machine flow

### F1. Feature flag
- **Constant:** `FeatureFlags.uploadVerificationEnabled = false` (Phase 0 default)
- **Behaviour:** when false, pre-check treats all upload states as confirmed. When true (Phase 1+), `pending` upload states block the flow.

### F2. Pre-check service
- **File:** new `Sources/AudioRecordingManager/ReturnMachine/ReturnMachinePreCheck.swift`
- **API:** inspects every sidecar, returns structured `PreCheckReport` — total counts, in-progress processing, pending uploads (gated by flag), unresolved drafts
- **Done when:** accurate report against seeded fixtures; blocks/allows based on severity

### F3. Return Machine view
- **File:** new `Sources/AudioRecordingManager/ReturnMachine/ReturnMachineView.swift`
- **Behaviour:** shows pre-check report; disables proceed button when blocked; shows friction gate when clear
- **Done when:** all branches render correctly; proceed button is disabled in every blocked state

### F4. Friction gate
- **Behaviour:** type-to-confirm (phrase: `SLETT ALLE FILER`, case-exact). Typos, lowercase, extra whitespace do not unlock.
- **Audit:** unlock emits `returnMachineStarted`
- **Done when:** only the exact phrase enables the wipe button

### F5. Secure delete walk
- **File:** new `Sources/AudioRecordingManager/ReturnMachine/SecureWipe.swift`
- **Behaviour:**
  - Walks every file under `recordings/`
  - Zero-overwrites content (one pass), then `unlink`
  - Removes directory structure
  - Flushes audit log, writes final `returnMachineCompleted`, then deletes audit log
- **Done when:** post-completion, data root is empty; `returnMachineCompleted` is the last entry written before log deletion

### F6. Wipe receipt
- **Path:** `~/Documents/ARM_wipe_receipt_YYYY-MM-DD_HHMMSS.txt`
- **Content:** timestamp, `NSUserName()`, machine hostname, count of recordings wiped, total bytes wiped, SHA-256 of final audit log before deletion
- **Done when:** receipt file exists in Documents post-wipe, content complete

### F7. Persistent handoff banner
- **Behaviour:** non-dismissible banner on the main view when `recordings/` is non-empty, pointing at Return Machine
- **Done when:** visible when data present, hidden when empty, no dismiss path

---

## Feature flags shipped in Phase 0

| Flag | Default | Behaviour |
|------|---------|-----------|
| `uploadVerificationEnabled` | `false` | Pre-check skips upload verification. Flip to `true` in Phase 1. |

---

## Acceptance definition for Phase 0

Phase 0 ships when:

- [ ] All tasks 0A–0F marked done
- [ ] `rg '\.desktopDirectory' Sources/` returns only `LegacyStorageScanner`
- [ ] `rg 'lydfiler\|tekstfiler' Sources/` returns no matches outside migration scanner + breadcrumb text
- [ ] Fresh-install run produces zero Desktop folders
- [ ] Upgrade-install run with seeded legacy Desktop data migrates cleanly
- [ ] Return Machine flow wipes the data root to zero files
- [ ] MDM sync exclusion is confirmed in place on one library machine
- [ ] FileVault confirmed mandated on library machines
- [ ] CHANGELOG updated under Unreleased with a summary of the pivot
