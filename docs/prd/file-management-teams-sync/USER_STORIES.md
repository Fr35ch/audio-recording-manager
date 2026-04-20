# User Stories: File Management & Teams Sync

**Epic:** File Management & Teams Sync
**Spec:** [FILE_MANAGEMENT_AND_TEAMS_SYNC.md](../../FILE_MANAGEMENT_AND_TEAMS_SYNC.md)
**Decision:** [ADR-1014](../../decisions/adr/ADR-1014-file-storage-architecture-pivot.md)
**Tasks:** [PHASE_0_TASKS.md](PHASE_0_TASKS.md)
**Date:** 2026-04-14 (revised)
**Status:** Draft — Phase 0 stories ready to build; Phase 1 and 2 stories pending research and external dependencies

---

## History

**Revised 2026-04-14.** The prior user stories (US-1 through US-7, covering manual file selection, OneDrive folder picker, and post-upload cleanup) were written against the superseded Desktop-storage architecture. They do not apply to the current design and have been replaced. The revised stories are numbered fresh to avoid confusion.

---

## Phase 0 — Storage, Migration, and Return Machine (no external dependencies)

These stories are buildable today and do not depend on researcher interviews, Azure AD registration, or MDM configuration.

---

### US-FM-01: My recordings don't sit on the Desktop

**As a** researcher,
**I want** my audio recordings and transcripts to be stored in a location that other users of this machine cannot casually see,
**so that** sensitive interview material is not exposed via Finder, Spotlight, or screen sharing.

#### Acceptance Criteria
- [ ] New recordings are written under `~/Library/Application Support/AudioRecordingManager/recordings/<uuid>/`
- [ ] Transcripts for new recordings land in the same per-recording folder
- [ ] `~/Desktop/lydfiler/` and `~/Desktop/tekstfiler/` are not created for new recordings
- [ ] No new code path writes audio or transcripts to `.desktopDirectory`
- [ ] Audit entry `recordingCreated` is emitted for every new recording

---

### US-FM-02: My existing recordings are moved to secure storage automatically

**As a** researcher upgrading to the new version,
**I want** any files currently on my Desktop to be moved into secure storage automatically on first launch,
**so that** I don't have to move them myself and nothing is lost or forgotten.

#### Acceptance Criteria
- [ ] On first launch of the new version, if `~/Desktop/lydfiler/` or `~/Desktop/tekstfiler/` exists with files, migration runs automatically
- [ ] Each `.m4a` is moved to a new UUID folder; sidecar is populated with `displayName` preserving the original filename stem and `createdAt` from file mtime
- [ ] Each `.txt` is matched to its audio by filename stem and moved to the correct recording folder
- [ ] Orphan transcripts (no matching audio) get their own recording folder with `audio.status = missing`
- [ ] Empty legacy Desktop folders are deleted after migration
- [ ] A breadcrumb file `~/Desktop/ARM_moved_to_secure_storage.txt` is left explaining what happened
- [ ] A one-time confirmation message is shown in-app after migration completes
- [ ] Subsequent launches do not re-run migration
- [ ] One `migrationCompleted` audit entry is written, not many

---

### US-FM-03: Filesystem renames don't break the link between audio and transcript

**As a** researcher,
**I want** audio and transcript files to be linked by a stable identity,
**so that** renaming or reorganizing files does not silently break my recordings list.

#### Acceptance Criteria
- [ ] Each recording is identified by UUID, stored in the metadata sidecar
- [ ] Audio-to-transcript association is via UUID (same folder) — never filename stem
- [ ] The UI displays `displayName` from the sidecar, not the filesystem name
- [ ] Renaming a file on disk (if someone navigates to the hidden folder and does so) does not break the UI; the UI continues showing `displayName` from the sidecar

---

### US-FM-04: The app knows when my recording is ready to hand in

**As a** researcher about to return the machine,
**I want** the app to check whether all my local data has been safely uploaded,
**so that** I don't accidentally wipe files that weren't backed up.

#### Acceptance Criteria
- [ ] A "Return Machine" view surfaces a pre-check report: total recordings, artifacts per recording, processing status, upload status
- [ ] Incomplete transcriptions block the Return Machine flow with a clear "wait for transcription to finish or discard this draft" message
- [ ] In Phase 0, upload verification is **stubbed behind a feature flag** (default: treat all uploads as confirmed). When the flag is enabled in Phase 1, unuploaded artifacts block the flow.
- [ ] The report and blocking states are fully rendered in all branches
- [ ] Audit entry `returnMachineStarted` is emitted when the researcher opens the flow

---

### US-FM-05: The wipe cannot be triggered accidentally

**As a** researcher,
**I want** the wipe action to require deliberate, typed confirmation,
**so that** I cannot delete all my research data by clicking through a familiar confirmation dialog.

#### Acceptance Criteria
- [ ] Wipe button is disabled until a fixed Norwegian phrase (e.g., `SLETT ALLE FILER`) is typed exactly (case-sensitive)
- [ ] Typos, lowercase variants, or extra whitespace do not unlock the button
- [ ] Unlocking the button emits an audit event
- [ ] No keyboard shortcut, context menu, or other path can trigger the wipe without the typed phrase

---

### US-FM-06: The wipe leaves no research data behind

**As a** researcher returning the machine,
**I want** the wipe to remove all local ARM data completely and verifiably,
**so that** the next user of this machine cannot recover interview material.

#### Acceptance Criteria
- [ ] After wipe, `~/Library/Application Support/AudioRecordingManager/recordings/` contains zero files
- [ ] File contents are zero-overwritten before unlink (one pass — APFS/SSD, not multi-pass)
- [ ] The audit log is deleted last, after the final `returnMachineCompleted` entry is flushed
- [ ] A receipt file is written to `~/Documents/ARM_wipe_receipt_<timestamp>.txt` containing: timestamp, `NSUserName()`, machine hostname, count of recordings wiped, total bytes wiped, SHA-256 of the final audit log
- [ ] The receipt survives the wipe (lives outside the ARM data root)

---

### US-FM-07: I cannot forget to run Return Machine before handing in

**As a** researcher,
**I want** a persistent reminder when local research data still exists on the machine,
**so that** I cannot forget to clean up before handoff.

#### Acceptance Criteria
- [ ] A banner is visible in the main UI whenever `recordings/` is non-empty
- [ ] The banner cannot be dismissed without running Return Machine
- [ ] Clicking the banner opens the Return Machine flow
- [ ] The banner hides automatically once the recordings folder is empty

---

### US-FM-08: My actions are auditable

**As a** compliance-responsible researcher,
**I want** every significant file action to be recorded in a tamper-resistant log,
**so that** I (or NAV) can verify what happened to the data after the fact.

#### Acceptance Criteria
- [ ] Audit log lives at `~/Library/Application Support/AudioRecordingManager/audit/audit-YYYY-MM.jsonl`
- [ ] Events are append-only JSONL with timestamp, actor, event type, structured payload
- [ ] Events logged in Phase 0: `recordingCreated`, `recordingFinalized`, `transcriptCompleted`, `transcriptFailed`, `migrationCompleted`, `returnMachineStarted`, `returnMachineCompleted`, `wipeReceiptWritten`
- [ ] Log rotates monthly (new file on first write of each month)
- [ ] Hash-chained tamper evidence deferred (`// TODO(audit-tamper)`); addressed after NAV compliance answer

---

## Phase 1 — Graph API Upload (blocked on Azure AD app registration)

These stories become buildable once NAV IT has granted the Entra ID app registration with the required Graph scopes.

---

### US-FM-09: My recording uploads itself when it's ready

**As a** researcher,
**I want** each recording to upload automatically as soon as it is finalized,
**so that** I don't have to remember a manual upload step and my work is in the NAV-approved secure storage.

#### Acceptance Criteria
- [ ] Audio uploads to the configured **private Teams channel** (study channel) when recording stops and the sidecar reaches `audio.status = finalized`
- [ ] Transcript uploads when transcription completes
- [ ] Anonymized transcript uploads if and only if the researcher produced one in ARM
- [ ] Analysis output uploads if and only if the researcher produced one in ARM
- [ ] If a consent form artifact is present, it uploads to the **consent channel** — a separate private channel configured for the project (not the study channel)
- [ ] ARM refuses to upload to a channel configured less than 24 hours ago and shows a clear message: «Kanalen ble opprettet for mindre enn 24 timer siden. Vent til ekskluderingen fra backup er gjennomført før du laster opp.»
- [ ] Filenames on Teams use the project's neutral code: `D01_20260414_audio.m4a`, `D01_20260414_transcript.txt`, etc. — never personal data, researcher initials, or UUID
- [ ] The compliance checklist (US-FM-15) must have been acknowledged for the project before any upload proceeds
- [ ] Each artifact's upload state is persisted in the sidecar (`pending | uploading | uploaded | failed`)
- [ ] Failed uploads are automatically retried on next app launch and on network availability changes
- [ ] Audit events `uploadQueued`, `uploadCompleted`, `uploadFailed` are emitted with destination channel reference

---

### US-FM-10: Large uploads resume if interrupted

**As a** researcher uploading a long interview,
**I want** an interrupted upload to resume rather than restart,
**so that** a dropped network connection or a closed lid doesn't cost me ten minutes of retrying.

#### Acceptance Criteria
- [ ] Files ≥ 4 MB use Graph `createUploadSession` with 10 MB chunks
- [ ] Resumable session URL is persisted in the sidecar
- [ ] On app restart, any recording with a pending upload and a stored session URL continues where it left off
- [ ] If the session has expired on Graph's side, ARM falls back to starting a fresh upload, logged as a `uploadFailed` with reason `sessionExpired`, then re-queued

---

### US-FM-11: Return Machine verifies real upload state

**As a** researcher about to wipe the machine,
**I want** the Return Machine pre-check to verify that Teams actually has each artifact,
**so that** I can't accidentally wipe files that only *appeared* to upload.

#### Acceptance Criteria
- [ ] Feature flag `uploadVerificationEnabled` defaults to `true` in this phase
- [ ] Pre-check queries Graph for each artifact's expected `driveItem` and confirms size + checksum match
- [ ] Any artifact that fails verification blocks the Return Machine flow with a clear remediation
- [ ] Pre-check is cancellable (researcher can abort if Graph is slow) but cannot be bypassed

---

### US-FM-12: Network is only on when I'm uploading

**As a** security-conscious researcher,
**I want** network access to be enabled only during upload windows,
**so that** the default state of the machine is air-gapped.

#### Acceptance Criteria
- [ ] `NetworkManager` is engaged for the duration of an upload attempt only
- [ ] Network is disabled again when the upload completes, fails, or is cancelled
- [ ] Multiple concurrent uploads share a single network-enabled window
- [ ] A safety timeout disables the network if no upload progress is observed for N seconds (existing zero-trust policy)

---

## Phase 2 — Project and Destination Model (blocked on researcher interviews)

These stories depend on operational answers that researcher interviews and conversations with NAV research ops will surface.

---

### US-FM-13: I can tell ARM which project I'm working on

**As a** researcher starting work on a new project,
**I want** ARM to know which project these recordings belong to,
**so that** they upload to the correct NAV-approved private Teams channel without per-file prompting.

#### Acceptance Criteria (draft — some details pending research findings)
- [ ] A project configuration screen lets the researcher specify: project name, study channel (Teams area + private channel ID), consent channel (separate private channel ID), and the participant neutral-code format (D01/D02 or T01/T02, etc.)
- [ ] ARM validates that the specified channels are accessible via Graph and warns if they appear to be less than 24 hours old
- [ ] Project configuration is stored in `state/app.json` under `currentProject.destinationRef`
- [ ] The researcher can switch projects; switching does not affect recordings already associated with a previous project
- [ ] ARM does **not** create Teams channels — it only uploads to channels that already exist and are configured by the researcher or IT

*Full acceptance criteria depend on research findings: does the researcher pick the channel, or does IT provision and share the channel ID?*

---

### US-FM-14: The Teams destination is auditable and deliberate

**As a** compliance-responsible researcher,
**I want** the Teams channel destination to be a recorded configuration, not an ad-hoc per-upload choice,
**so that** recordings cannot end up in a channel that is not backup-excluded or not compliant with the NAV insight data routine.

#### Acceptance Criteria (draft — some details pending research findings)
- [ ] The configured destination includes both a study channel and a consent channel — two distinct private channel IDs
- [ ] ARM verifies at configuration time (not at upload time) that the channels exist and are reachable via Graph
- [ ] The configured destination is stored with a `configuredAt` timestamp so it is auditable
- [ ] ARM surfaces a warning if the same channel ID is set for both study and consent artifacts
- [ ] There is no way to initiate an upload without a saved, validated project configuration

*Full acceptance criteria depend on the picker-vs-provisioned decision.*

---

### US-FM-15: I confirm compliance requirements before my first upload

**Added:** 2026-04-17
**Source:** NAV routine for midlertidig lagring av innsiktsdata (ref. PVK 25/35628)
**Depends on:** US-FM-13 (project must be configured)
**Blocks:** US-FM-09 (no upload without this acknowledgement)

**As a** studieansvarlig,
**I want** ARM to present the compliance requirements from NAV's insight data routine before any data is uploaded,
**so that** I confirm I have met my obligations under the routine and the acknowledgement is recorded in the audit log.

#### Acceptance Criteria
- [ ] Before the first upload in a new project, ARM shows a compliance checklist that the researcher must actively check each item on:
  - Deltakerne er informert om innsiktsarbeidet og har gitt gyldig samtykke
  - Ingen deltakere med kode 6 eller 7 er inkludert i datamaterialet
  - Ingen deltakere under 18 år er inkludert
  - Lydopptak er godkjent gjennom risikovurdering og annen relevant dokumentasjon
  - Ingen video eller bilder av deltakere er inkludert
  - En datahåndteringsplan er på plass og oppdatert
- [ ] All items must be checked before the «Bekreft og last opp» button is enabled
- [ ] Confirmation is recorded as a `complianceCheckConfirmed` audit event with timestamp and project ID
- [ ] The checklist is not shown again for subsequent uploads in the same project unless the project configuration changes
- [ ] A «Les mer» link for each item opens the relevant section of the NAV routine (external URL, configurable)
- [ ] The checklist is also accessible from the project settings view at any time

#### Out of scope
- ARM verifying that the researcher's claims are true (participant consent, age, etc.) — this is researcher responsibility
- Archiving the data management plan to Public 360 — done outside ARM

---

### US-FM-16: My files are named with neutral codes, not personal data

**Added:** 2026-04-17
**Source:** NAV routine for midlertidig lagring av innsiktsdata — section 8
**Depends on:** US-FM-13 (neutral code format set in project config)

**As a** researcher uploading to Teams,
**I want** ARM to automatically use neutral participant codes in filenames,
**so that** uploaded files cannot identify participants by name and comply with the NAV routine.

#### Acceptance Criteria
- [ ] ARM generates the Teams filename from the project's neutral code, the recording date, and the artifact type: `D01_20260414_audio.m4a`, `D01_20260414_transcript.txt`, `D01_20260414_transcript_anonymized.txt`, `D01_20260414_analysis.json`
- [ ] The researcher sets the neutral code for each recording (e.g. D01, D02) from the recording detail view; it defaults to a sequential `D##` if not set
- [ ] ARM never derives a filename from the recording's `displayName`, the researcher's name, or any field that could contain personal data
- [ ] The local UUID → Teams filename mapping is stored in the sidecar (`upload.audio.remoteName`, etc.) so the relationship is auditable
- [ ] If a neutral code is not set at upload time, ARM blocks the upload and prompts the researcher to set one

---

## Priority Order (Phase 0)

| Priority | Story | Rationale |
|----------|-------|-----------|
| 1 | US-FM-01 | Foundation — stops the Desktop leak |
| 2 | US-FM-03 | Foundation — UUID identity replaces stem coupling |
| 3 | US-FM-08 | Foundation — audit log infrastructure everything else depends on |
| 4 | US-FM-02 | Migration — required before shipping to existing users |
| 5 | US-FM-07 | Safety — reminder that Return Machine exists |
| 6 | US-FM-04 | Handoff — pre-check logic |
| 7 | US-FM-05 | Handoff — friction gate |
| 8 | US-FM-06 | Handoff — secure delete + receipt |

Phase 1 stories sequence after US-FM-08 infrastructure is in place and Azure AD registration is approved. US-FM-15 and US-FM-16 are Phase 1 prerequisites — US-FM-09 depends on both.

---

## Superseded Stories (historical reference)

The following stories from the prior draft of this document do not apply to the current architecture and are preserved here only for reference when reading older commits:

- ~~US-1: Select files for upload~~ — replaced by automatic per-artifact upload (US-FM-09)
- ~~US-2: Choose destination folder in OneDrive~~ — replaced by per-project Teams destination (US-FM-13)
- ~~US-3: Copy files to OneDrive with progress~~ — replaced by Graph API direct upload (US-FM-09, US-FM-10)
- ~~US-4: Post-upload cleanup~~ — replaced by decoupled local-lifecycle + Return Machine (US-FM-06)
- ~~US-5: Track upload status in metadata~~ — subsumed into US-FM-09 (upload state lives in sidecar)
- ~~US-6: Audit logging for uploads~~ — subsumed into US-FM-08
- ~~US-7: Anonymization gate before upload~~ — removed; anonymization is post-upload on OneDrive (see ADR-1014)
