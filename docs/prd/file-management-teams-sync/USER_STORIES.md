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

### US-FM-08: My actions are auditable

**As a** compliance-responsible researcher,
**I want** every significant file action to be recorded in a tamper-resistant log,
**so that** I (or NAV) can verify what happened to the data after the fact.

#### Acceptance Criteria
- [ ] Audit log lives at `~/Library/Application Support/AudioRecordingManager/audit/audit-YYYY-MM.jsonl`
- [ ] Events are append-only JSONL with timestamp, actor, event type, structured payload
- [ ] Events logged in Phase 0: `recordingCreated`, `recordingFinalized`, `transcriptCompleted`, `transcriptFailed`, `recordingExpiryWarning`, `recordingExpired`, `migrationCompleted`
- [ ] Log rotates monthly (new file on first write of each month)
- [ ] Hash-chained tamper evidence deferred (`// TODO(audit-tamper)`); addressed after NAV compliance answer

---

### US-FM-17: Local recordings are automatically deleted after 30 days

**Added:** 2026-04-20
**Rationale:** Interview data is sensitive personal data and should not reside on the researcher's machine beyond what is necessary. 30 days is sufficient time to upload, review, and annotate — retaining data longer than this increases privacy risk without benefit.

**As a** researcher,
**I want** recordings to be automatically deleted from my machine after 30 days,
**so that** sensitive interview data does not linger on my machine longer than necessary.

#### Acceptance Criteria

**Countdown and warnings:**
- [ ] Each recording tracks a 30-day expiry based on `createdAt` in its sidecar — clock is never reset
- [ ] At day 23 (7 days remaining): a persistent per-recording banner appears in the recording list and detail view: «Opptaket slettes automatisk om 7 dager»
- [ ] At day 29 (1 day remaining): the banner escalates with urgent styling: «Opptaket slettes i morgen»
- [ ] If the recording has not been uploaded, an additional warning is shown alongside the countdown: «Dette opptaket er ikke lastet opp — last opp før det slettes automatisk»
- [ ] Warning banners cannot be dismissed — they resolve only when the recording is deleted

**Automatic deletion:**
- [ ] On app launch, ARM checks all recordings for expired entries (`createdAt + 30 days ≤ now`)
- [ ] Expired recordings are deleted: entire `recordings/<uuid>/` folder — audio, transcript, anonymized transcript, analysis, and sidecar
- [ ] Deletion is not blocked by upload state — the warning is informational, not a gate
- [ ] Audit event `recordingExpired` is emitted with `recordingId`, `createdAt`, `deletedAt`, and upload status at time of deletion
- [ ] Audit event `recordingExpiryWarning` is emitted at day 23 and day 29 with `recordingId` and `daysRemaining`

#### Out of scope
- Extending the 30-day clock based on user activity (no snooze or extension mechanism)
- Per-recording opt-out of automatic deletion

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
| 5 | US-FM-17 | Compliance — 30-day local retention with automatic expiry and warnings |

Phase 1 stories sequence after US-FM-08 infrastructure is in place and Azure AD registration is approved. US-FM-15 and US-FM-16 are Phase 1 prerequisites — US-FM-09 depends on both.

---

## Superseded Stories (historical reference)

The following stories from the prior draft of this document do not apply to the current architecture and are preserved here only for reference when reading older commits:

- ~~US-1: Select files for upload~~ — replaced by automatic per-artifact upload (US-FM-09)
- ~~US-2: Choose destination folder in OneDrive~~ — replaced by per-project Teams destination (US-FM-13)
- ~~US-3: Copy files to OneDrive with progress~~ — replaced by Graph API direct upload (US-FM-09, US-FM-10)
- ~~US-4: Post-upload cleanup~~ — replaced by 30-day automatic expiry (US-FM-17)
- ~~US-5: Track upload status in metadata~~ — subsumed into US-FM-09 (upload state lives in sidecar)
- ~~US-6: Audit logging for uploads~~ — subsumed into US-FM-08
- ~~US-7: Anonymization gate before upload~~ — removed; anonymization runs inside ARM before upload (see ADR-1014)
- ~~US-FM-04: Return Machine pre-check~~ — removed; Return Machine feature dropped
- ~~US-FM-05: Typed wipe confirmation~~ — removed; Return Machine feature dropped
- ~~US-FM-06: Secure delete + receipt~~ — removed; Return Machine feature dropped
- ~~US-FM-07: Handoff reminder banner~~ — removed; Return Machine feature dropped
- ~~US-FM-11: Return Machine upload verification~~ — removed; Return Machine feature dropped
- ~~US-FM-12: Network only on during upload~~ — removed; ARM no longer manages network state
