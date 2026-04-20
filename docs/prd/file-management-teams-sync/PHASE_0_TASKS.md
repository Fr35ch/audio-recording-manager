# Phase 0 Build Tasks — File Management

**Epic:** File Management & Teams Sync
**Phase:** 0 — Safe Storage, Migration, and Local Retention
**Spec:** [FILE_MANAGEMENT_AND_TEAMS_SYNC.md](../../FILE_MANAGEMENT_AND_TEAMS_SYNC.md)
**Stories:** [USER_STORIES.md](USER_STORIES.md)
**Decision:** [ADR-1014](../../decisions/adr/ADR-1014-file-storage-architecture-pivot.md)
**Updated:** 2026-04-20 — Return Machine removed; 30-day expiry added as 0F

---

## Scope

Phase 0 delivers the storage pivot end-to-end, **except** the actual Graph/Teams upload (Phase 1).

**In scope:**
- New storage layout under `~/Library/Application Support/AudioRecordingManager/`
- UUID-named recording folders with metadata sidecars
- Audit log with typed events and monthly rotation
- One-shot migration from legacy Desktop folders
- Rewiring the app to use `RecordingStore`
- Removing all Desktop write paths
- 30-day local retention with expiry warnings and automatic deletion

**Not in scope (Phase 1 or later):**
- Microsoft Graph API upload
- Project concept in the UI
- Teams destination picker
- Hash-chained audit log

---

## Status key

| Symbol | Meaning |
|--------|---------|
| ✅ | Done and tested |
| 🔄 | Partially done |
| ❌ | Not started |

---

## External dependencies

| Dependency | Owner | Blocks | Status |
|------------|-------|--------|--------|
| MDM sync exclusion of ARM data path | mac-fleet admin | Phase 0 ship | To request |
| Azure AD / Entra ID app registration | NAV IT | Phase 1 only | Request now (long lead) |

---

## Sequencing

```
0A (storage foundation) ──✅
0B (audit logger)        ──✅──► 0D (rewire) ──► 0E (cleanup) ──► 0F (expiry)
0C (migration)           ──✅
```

---

## 0A — Storage foundation ✅

All four tasks complete.

- ✅ **A1** `StorageLayout.swift` — typed path helpers, `ensureDirectoriesExist()`
- ✅ **A2** `RecordingMeta.swift` — full sidecar schema, forward-compat decode, `schemaVersion`
- ✅ **A3** `RecordingStore.swift` — `create`, `load`, `loadAll`, `updateMeta`, `delete`, per-recording queues, atomic writes, `didChangeNotification`
- ✅ **A4** Audio integrity hash — SHA-256 written into sidecar via `RecordingStore.finalize()`

---

## 0B — Audit logger ✅

All six tasks complete.

- ✅ **B1** Writes to `~/Library/Application Support/AudioRecordingManager/audit/audit-YYYY-MM.jsonl`
- ✅ **B2** `AuditEvent` + `AuditValue` types; typed `AuditEventType` enum
- ✅ **B3** Monthly rotation
- ✅ **B4** Removed stale Return Machine event cases (`returnMachineStarted`, `returnMachineCompleted`, `wipeReceiptWritten`) from `AuditEventType`
- ✅ **B5** Added `recordingExpiryWarning` and `recordingExpired` event cases; typed helpers `logExpiryWarning(recordingId:daysRemaining:)` and `logExpired(recordingId:createdAt:deletedAt:uploadStatus:)`
- ✅ **B6** Added `complianceCheckConfirmed` event case; typed helper `logComplianceCheckConfirmed(projectId:)`

---

## 0C — Migration from legacy Desktop folders ✅

All infrastructure complete.

- ✅ **C1** `LegacyStorageScanner.swift` — detects and counts legacy Desktop folders
- ✅ **C2** `StorageMigrator.swift` — moves audio + transcripts into UUID folders, orphan handling, audit entry
- ✅ **C3** One-shot on first launch gated by `migrationCompletedAt` in `AppState`
- ✅ **C4** Post-migration confirmation UI ("Moved N recordings to secure storage")
- ✅ **C5** Removes empty legacy Desktop folders; writes breadcrumb file

**Verify before ship:** `rg 'lydfiler|tekstfiler' Sources/` returns no matches outside `LegacyStorageScanner`.

---

## 0D — Rewire the app to use `RecordingStore` 🔄

- ✅ **D1** `AudioRecorder` calls `RecordingStore.create()` on start, `finalize()` on stop; audio lands in UUID folder; `recordingCreated` + `recordingFinalized` audit entries emitted
- ❌ **D2** `TranscriptionService` writes transcript into the recording's folder and updates sidecar via `store.updateMeta()`; `transcriptCompleted`/`transcriptFailed` audit entries emitted
- ✅ **D3** `RecordingsManager` builds list from `RecordingStore.loadAll()`; sorted by `createdAt`
- ✅ **D4** `TranscriptManager` enumerates from `RecordingStore`; subscribes to `didChangeNotification`
- ❌ **D5** All `URL(fileURLWithPath: recording.path)` sites replaced with `StorageLayout` calls

  Known remaining sites in `main.swift` (from grep 2026-04-20):
  - `AudioFileManager` class (retired in D6)
  - Lines ~2825, ~3213, ~3358 — file reveal / Desktop write UI
  - Lines ~4146, ~4550, ~4753 — `lydfiler` path construction in UI views

- ❌ **D6** `AudioFileManager` class deleted; timestamp-formatting logic absorbed into `RecordingStore`

**Done when:** `rg 'URL\(fileURLWithPath: recording\.path' Sources/` returns zero matches outside the store; app builds and records correctly.

---

## 0E — Remove Desktop egress ❌

- ❌ **E1** Strip all `.desktopDirectory` usage outside `LegacyStorageScanner`

  Known sites in `main.swift` (from grep 2026-04-20): lines 86, 88, 4146, 4147

- ❌ **E2** Remove "Reveal in Finder / Save to Desktop" UI actions (menu items, toolbar buttons)
- ❌ **E3** Strip `NSSharingServicePicker` / `NSSharingService` usage for audio/transcript files

**Done when:**
- `rg '\.desktopDirectory' Sources/` returns only `LegacyStorageScanner`
- `rg 'NSSharingService' Sources/` returns no matches in audio/transcript flow

---

## 0F — 30-day local retention ❌

> **Goal:** Recordings are automatically deleted 30 days after creation. Warnings shown at day 23 and day 29. No manual wipe flow. Fully audited.
>
> **Story:** [US-FM-17](USER_STORIES.md#us-fm-17-local-recordings-are-automatically-deleted-after-30-days)

### F1. `RecordingExpiryManager`

- **File:** new `Sources/AudioRecordingManager/Storage/RecordingExpiryManager.swift`
- **API:**
  - `checkAndExpire()` — runs on every app launch; iterates `RecordingStore.loadAll()`, deletes any recording where `createdAt + 30 days ≤ now`, emits `recordingExpired` audit event per deletion
  - `expiryDate(for:) -> Date` — `createdAt + 30 days`
  - `daysRemaining(for:) -> Int` — days until expiry (negative = already expired)
  - `warningState(for:) -> ExpiryWarningState` — `.none | .sevenDays | .oneDay | .expired`
- **Rules:**
  - Clock is `createdAt` — never reset by any action
  - Deletion is not blocked by upload state; logs upload status at time of deletion in the audit payload
  - Calls `RecordingStore.delete(id:)` then emits audit event
- **Done when:** unit tests cover expired, day-23, day-29, and day-0 cases with a controlled clock

### F2. Call `checkAndExpire()` on launch

- **Change:** call `RecordingExpiryManager.shared.checkAndExpire()` early in app startup, after `StorageLayout.ensureDirectoriesExist()` and after migration check
- **Order:** migration → expiry check → load recordings
- **Done when:** seeding a recording with `createdAt = 31 days ago` and launching deletes it before the recordings list loads

### F3. `ExpiryWarningBanner` view component

- **File:** new `Sources/AudioRecordingManager/ExpiryWarningBanner.swift`
- **Behaviour:**
  - Shown inline in the recording list row and in `RecordingDetailView` when `warningState != .none`
  - Day 23–28: «Opptaket slettes automatisk om X dager» — standard warning style
  - Day 29: «Opptaket slettes i morgen» — elevated/urgent styling (`AppColors.warning` or similar)
  - If `upload.audio.status != .uploaded`: additional line «Opptaket er ikke lastet opp»
  - Not dismissible — resolves only when the recording is deleted
- **Done when:** all three states render correctly; no dismiss button or gesture exists

### F4. Emit `recordingExpiryWarning` audit events

- **Behaviour:** on each launch, for every recording in `.sevenDays` or `.oneDay` warning state that has not yet had a warning logged for today, emit `recordingExpiryWarning` with `recordingId` and `daysRemaining`
- **Deduplication:** store `lastWarningDate` in the sidecar (or check audit log) so the same recording doesn't produce a warning entry on every launch within the same day
- **Done when:** a recording at day 23 produces exactly one `recordingExpiryWarning` per calendar day, not one per launch

### F5. Acceptance

- [ ] Recording created 31 days ago is deleted on next launch before UI loads
- [ ] `recordingExpired` audit event written with `recordingId`, `createdAt`, `deletedAt`, `uploadStatus`
- [ ] Day-23 and day-29 banners render in correct styles; no dismiss path
- [ ] Upload-not-uploaded supplementary warning shown when applicable
- [ ] `rg 'RecordingExpiryManager\|checkAndExpire' Sources/` shows exactly one call site in app startup

---

## Phase 0 ship checklist

- [ ] All tasks 0A–0F marked done above
- [ ] `rg '\.desktopDirectory' Sources/` returns only `LegacyStorageScanner`
- [ ] `rg 'lydfiler\|tekstfiler' Sources/` returns no matches outside migration scanner + breadcrumb text
- [ ] Fresh-install run produces zero Desktop folders
- [ ] Upgrade-install run with seeded legacy Desktop data migrates cleanly
- [ ] Recording created 31 days ago is deleted on next launch
- [ ] MDM sync exclusion is confirmed in place
- [ ] CHANGELOG updated under Unreleased
