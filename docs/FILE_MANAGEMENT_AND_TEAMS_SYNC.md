# File Management & Teams Sync

**Date:** 2026-04-14 (revised from draft of same date)
**Status:** Draft — Phase 0 scoped and ready to build
**Supersedes:** Earlier draft of this document (pre-2026-04-14) that relied on Desktop storage + manual OneDrive folder-picker upload.
**Related:** [ADR-1014](decisions/adr/ADR-1014-file-storage-architecture-pivot.md), [USER_STORIES.md](prd/file-management-teams-sync/USER_STORIES.md), [PHASE_0_TASKS.md](prd/file-management-teams-sync/PHASE_0_TASKS.md), [SPEC.md](../SPEC.md), [BACKLOG.md](../BACKLOG.md)

---

## Overview

This spec defines the end-to-end file lifecycle for ARM recordings and transcripts: where they live on disk, how they are identified, how they are uploaded to Microsoft Teams / SharePoint.

The earlier version of this spec assumed Desktop storage + a user-driven OneDrive folder-picker upload. That model had several problems documented in [ADR-1014](decisions/adr/ADR-1014-file-storage-architecture-pivot.md). This revision supersedes it.

---

## Current State (what we're moving away from)

- **Audio** stored at `~/Desktop/lydfiler/lydfil_YYYYMMDD_HHMMSS.m4a`
- **Transcripts** stored at `~/Desktop/tekstfiler/<stem>.txt`
- Audio ↔ transcript linked by **filename stem** (breaks on Finder rename)
- **Audit log** is a hidden dotfile `.audit_log.jsonl` inside the audio folder (user-editable)
- **Egress** via `uploadToTeams()` in [main.swift](../Sources/AudioRecordingManager/main.swift): enables network, opens Teams + Finder + OneDrive, user drags files manually

## Target State (this spec)

- All data under `~/Library/Application Support/AudioRecordingManager/`, **excluded from roaming profile sync via MDM**
- Each recording is a **UUID-named folder** containing audio + transcript + metadata sidecar
- Audit log in the same data root, monthly-rotated, append-only JSONL
- **Direct Graph API upload** to a per-project Teams/SharePoint location — no Finder dragging
- **Per-artifact automatic upload** when each artifact reaches a stable final state
- **Return Machine flow** is the only path that deletes local data

---

## Storage Layout

```
~/Library/Application Support/AudioRecordingManager/
  recordings/
    7f3a2b1c-.../
      audio.m4a
      transcript.txt
      meta.json
    8a4c1d2e-.../
      audio.m4a
      meta.json                 # transcript still processing
  audit/
    audit-2026-04.jsonl         # append-only, monthly rotated
    audit-2026-05.jsonl
  state/
    app.json                    # app-level state: migration markers, current project
```

Rationale for per-recording folders: atomic move/delete/wipe, clear ownership of related files, and no cross-contamination when wiping a single recording.

---

## Metadata Sidecar Schema (`meta.json`)

```json
{
  "schemaVersion": 1,
  "id": "7f3a2b1c-0000-0000-0000-000000000000",
  "createdAt": "2026-04-14T10:23:00Z",
  "displayName": "Interview 2026-04-14",
  "durationSeconds": 1847,
  "audio": {
    "filename": "audio.m4a",
    "sizeBytes": 12345678,
    "sha256": "…"
  },
  "transcript": {
    "filename": "transcript.txt",
    "status": "done",
    "engine": "whisper-large-v3",
    "completedAt": "2026-04-14T10:55:12Z"
  },
  "anonymization": { "status": "none" },
  "upload": {
    "audio":      { "status": "pending" },
    "transcript": { "status": "pending" }
  }
}
```

- `schemaVersion` is present from day one so future changes can migrate rather than break.
- `status` enums use `pending | processing | done | failed | uploaded | none` (per-field semantics).
- Unknown fields on decode are tolerated to preserve forward compatibility.
- All writes are atomic (temp-file-then-rename).

---

## Storage Security Model

We rely on the OS and fleet configuration, not our own crypto:

| Layer | Mechanism | Owner |
|-------|-----------|-------|
| Per-user isolation on shared library machines | macOS user account permissions | OS |
| At-rest encryption | FileVault (mandated by NAV IT) | NAV IT |
| Non-replication to other NAV-issued machines | MDM excludes `~/Library/Application Support/AudioRecordingManager/` from the roaming profile sync | NAV IT (mac-fleet admin) |
| Machine cleanliness on return | ARM's Return Machine flow + IT account deprovisioning | ARM + NAV IT |

The **MDM sync exclusion** is the single load-bearing configuration item outside ARM's source tree. If it is not in place, this entire plan's threat model fails. Confirm before Phase 0F ships.

---

## Lifecycle Model

Two independent lifecycles govern each recording:

### Upload lifecycle — per artifact, automatic

Each artifact (audio, transcript, anonymized transcript if produced, analysis output if produced) transitions independently:

```
pending → uploading → uploaded
                   ↘ failed (retry on next app launch / network change)
```

Triggers:
- **Audio**: uploads when recording stops and sidecar reaches `audio.status = finalized`.
- **Transcript**: uploads when transcription completes.
- **Anonymization / analysis**: upload if produced in ARM. Optional — many researchers do these elsewhere.

No manual "upload" button. The researcher never chooses *when* to upload an individual file.

### Local lifecycle — bounded only by Return Machine

Local files **persist independently of upload state**. They are not deleted when upload succeeds. They are deleted only when the researcher runs the Return Machine flow. Local retention is bounded by the researcher's use of the machine, not by upload or clock.

There is **no local 30-day cap**. OneDrive enforces the 30-day retention on the uploaded copies; that is NAV's existing policy.

---

## Egress: Graph API Upload to Teams/SharePoint

### Destination

A **NAV-provisioned private Teams channel**, excluded from backup. This is not a general SharePoint document library or a public channel — it must be the backup-excluded private channel type specifically provisioned for insight data under the NAV routine for temporary storage of insight data with personal data (ref. PVK 25/35628).

Naming convention for Teams areas: `Innsiktslagring [PO/team name] [sequential number]`, e.g. `Innsiktslagring Designseksjonen 01`. Private channels within the area are named per study or team need.

**Consent forms use a separate private channel** from audio, transcripts, and notes. ARM must distinguish between artifact types and route them to the correct channel:
- Audio, transcript, anonymized transcript, analysis → study channel
- Consent forms → separate consent channel (access restricted further, ideally study lead only)

The exact destination (Team ID + private Channel ID, per artifact type) is configured **once per project** and stored in `state/app.json` as a `destinationRef`. Whether this is researcher-chosen or IT-provisioned depends on answers still pending from the NAV research-ops / mac-fleet conversations.

**24-hour wait after channel creation.** When a private channel is newly created, it takes approximately 24 hours for the backup exclusion to propagate through M365. ARM must not upload to a channel that was created less than 24 hours ago. This constraint is surfaced to the researcher as a clear warning, not silently ignored.

### Authentication

- OAuth 2.0 (Authorization Code + PKCE) against Entra ID with the researcher's NAV work account.
- Scopes (delegated): `Files.ReadWrite`, `Sites.ReadWrite.All`, `User.Read`.
- Requires **Azure AD / Entra ID app registration** in NAV's tenant. This is a pre-requisite and has long lead time (weeks).

### Upload mechanism

- **Small files (<4 MB)**: `PUT /sites/{site-id}/drive/items/{parent}:/filename:/content`
- **Large files (≥4 MB)**: resumable upload session via `/createUploadSession`, chunked at 10 MB.
- Resumable state persisted in sidecar's `upload.<artifact>.sessionUrl` so a crashed upload resumes rather than restarts.

### Naming on Teams

On-disk filenames are UUIDs (opaque). On Teams, files use a convention that is **human-readable but contains no personal data** — the NAV routine explicitly prohibits using participant names, IDs, or any personal identifiers in filenames on these channels.

ARM uses the following format:

```
<neutral-code>_<YYYYMMDD>_<artifact-type>.<ext>

Examples:
D01_20260414_audio.m4a
D01_20260414_transcript.txt
D01_20260414_transcript_anonymized.txt
D01_20260414_analysis.json
```

Where `<neutral-code>` is a project-local participant code (e.g. D01, D02 — Deltaker 1, 2) set by the researcher when configuring the project, not derived from any personal information. The mapping between local UUID and remote filename is stored in the sidecar so the relationship is auditable.

The researcher sets the `neutralCode` for a recording (or it defaults to a sequential `D##` if not set). ARM must never derive a filename from a person's name, initials, NAV case ID, or any other personal identifier.

### Network control

Existing `NetworkManager` zero-trust model still applies: network is enabled only for the duration of an upload attempt. Between uploads, network returns to the default-off state.

---

## Teams-Side Retention Policy (M365, not ARM)

The following retention rules are enforced by Teams/M365, not by ARM. ARM is responsible for surfacing them clearly to the researcher — not for implementing them.

| Event | Timing | Who triggers |
|-------|--------|--------------|
| Warning to delete or anonymize | 90 days after upload | M365 automatic notification to study channel and researcher's private channel |
| Automatic file deletion | 8 months after upload | M365 |
| Files move to M365 recycle bin | At deletion | M365 (93 days before permanent erasure) |

ARM should display this retention policy prominently in the upload confirmation UI and in the project settings view, so researchers plan their anonymization and handoff timelines accordingly.

**The absence of backup is a deliberate privacy control.** Files on these private channels are intentionally excluded from backup so that when data is deleted — including by the 8-month auto-deletion — it is fully gone, with no recovery path. ARM copy materials should use the word "midlertidig lagring" (temporary storage) and make clear that upload to Teams is not a permanent archive.

---

## Compliance Constraints

These constraints come from the NAV routine for temporary storage of insight data (ref. PVK 25/35628). ARM cannot technically enforce all of them but must surface them at appropriate points in the workflow.

### What ARM enforces technically
- **No personal data in filenames.** ARM generates the filename for upload using neutral codes only (see Naming on Teams above). The researcher cannot override this with a free-text filename on upload.
- **24-hour channel age check.** ARM blocks or warns before uploading to a channel created less than 24 hours ago.
- **No Microsoft Copilot.** ARM must not call any Microsoft Copilot API against files in these channels or their content.
- **Separate consent channel.** ARM routes consent-form artifacts to a distinct channel from audio/transcript artifacts.

### What ARM surfaces as a compliance reminder
Before the first upload in a project, and accessible via a persistent info panel, ARM shows a checklist that the researcher must acknowledge:

- [ ] Deltakerne er informert om innsiktsarbeidet og har gitt gyldig samtykke.
- [ ] Ingen deltakere med kode 6 eller 7 er inkludert i datamaterialet.
- [ ] Ingen deltakere under 18 år er inkludert.
- [ ] Lydopptak er godkjent gjennom risikovurdering og annen relevant dokumentasjon.
- [ ] Ingen video eller bilder av deltakere er inkludert.
- [ ] En datahåndteringsplan er på plass og oppdatert.

This acknowledgement is logged as a `complianceCheckConfirmed` audit event with timestamp and recording IDs covered. It is not re-shown for subsequent uploads in the same project unless the project configuration changes.

### What is out of ARM's scope
- Verifying that participants have valid consent (researcher responsibility)
- Enforcing participant age or protection codes (ARM has no access to NAV person registers)
- Archiving consent forms and the data management plan to Public 360 (done outside ARM)

---

## Return Machine Flow

The only path that deletes local ARM data. Researcher-initiated, heavily friction-gated, fully audited.

**Steps:**

1. **Pre-check** — inspect every recording sidecar, report counts, flag any incomplete processing, any uploads not yet confirmed. If anything is incomplete, block the flow with a clear remediation path ("upload these first", "let transcription finish", "discard this draft").
2. **Friction gate** — researcher types a fixed phrase (e.g., `SLETT ALLE FILER`). Case-exact. Typed, not clicked.
3. **Secure delete walk** — zero-overwrite then unlink every file under `recordings/`. One pass; on APFS/SSD more passes are security theatre. Remove directory structure.
4. **Receipt** — write `~/Documents/ARM_wipe_receipt_<timestamp>.txt` with: timestamp, `NSUserName()`, machine hostname, count wiped, total bytes wiped, SHA-256 of the final audit log before deletion.
5. **Final audit entry** — append `returnMachineCompleted` to the audit log.
6. **Delete audit log last** — after the final entry is flushed to disk.

The receipt file deliberately lives in `~/Documents/` (outside the ARM data root) so it survives the wipe and provides external evidence that the wipe happened.

**Persistent handoff-reminder banner:** when `recordings/` is non-empty, the main UI shows a non-dismissible banner pointing at the Return Machine flow. No dismiss button.

---

## Audit Log

- **Location**: `~/Library/Application Support/AudioRecordingManager/audit/audit-YYYY-MM.jsonl`
- **Format**: append-only JSONL, one event per line
- **Rotation**: monthly (new file opened on first write of each month)
- **Uploaded**: the current month's log is uploaded to OneDrive as the final artifact of Return Machine, before local deletion
- **Event types** (initial set): `recordingCreated`, `recordingFinalized`, `transcriptCompleted`, `transcriptFailed`, `transcriptEdited`, `transcriptAnonymized`, `transcriptAnalysed`, `anonymizationStarted`, `anonymizationDiscarded`, `complianceCheckConfirmed`, `uploadQueued`, `uploadCompleted`, `uploadFailed`, `migrationCompleted`, `returnMachineStarted`, `returnMachineCompleted`, `wipeReceiptWritten`

Hash-chained tamper evidence is intentionally out of scope for Phase 0. Track as `// TODO(audit-tamper)` for post-Phase-0 hardening pending NAV compliance answer on log format requirements.

---

## Migration from Current Desktop Storage

One-shot pass on first launch of the version that introduces this architecture:

1. `LegacyStorageScanner` detects `~/Desktop/lydfiler/` and `~/Desktop/tekstfiler/`.
2. For each `.m4a`: mint UUID, create recording folder, move audio in as `audio.m4a`, write initial sidecar with `displayName` = original stem and `createdAt` = file mtime.
3. For each `.txt`: match to audio by stem, move as `transcript.txt` inside the same recording folder, update sidecar.
4. Orphan transcripts (no matching audio): create recording folder with `audio.status = missing`.
5. Write `migrationCompleted` audit event.
6. Delete empty legacy Desktop folders; leave a single `~/Desktop/ARM_moved_to_secure_storage.txt` breadcrumb explaining where data went.
7. Record `migrationCompletedAt` in `state/app.json`; subsequent launches skip migration.

Migration is **mandatory and non-interactive**. A brief one-time confirmation ("Moved N recordings to secure storage") is shown after completion. There is no opt-out — Desktop storage is non-compliant under the new architecture.

---

## Out of Scope for Phase 0

These are deliberately deferred:

- Microsoft Graph API upload (Phase 1 — blocked on Azure AD app registration)
- Project concept in the UI (Phase 2 — needs researcher interview findings)
- Teams/SharePoint destination picker vs. IT-provisioned config decision (Phase 2 — needs operational answer)
- Researcher-facing UX tuning beyond the minimum needed for Return Machine
- Hash-chained tamper evidence on audit log

See [PHASE_0_TASKS.md](prd/file-management-teams-sync/PHASE_0_TASKS.md) for the full Phase 0 build order.

---

## Load-Bearing External Dependencies (kick off now)

| Dependency | Owner | Blocks |
|------------|-------|--------|
| MDM sync exclusion of `~/Library/Application Support/AudioRecordingManager/` | mac-fleet admin | Phase 0F (Return Machine ship) |
| FileVault mandate confirmed and enforced on library machines | NAV IT | Phase 0F |
| Azure AD / Entra ID app registration with Graph scopes (`Files.ReadWrite`, `Sites.ReadWrite.All`, `User.Read`, `ChannelMessage.Read.All` for channel age check) | NAV IT | Phase 1 (Graph API upload) |
| Confirmation that the target private channels are already provisioned and backup-excluded for each product area | Team ResearchOps (Ståle Kjone) | Phase 1 (upload can't go live without at least one valid target channel) |
| Answer: researcher-picked channel vs ARM uses a pre-configured channel per project? | Research ops / mac-fleet admin | Phase 2 (destination UX) |
| Answer: does ARM need to create private channels itself, or only upload to existing ones? | NAV IT / Team M365 | Phase 2 (channel management UX) |
| Answer: audit log format/retention — NAV-specified or internal? | NAV compliance / DPO | Phase 0F polish (schema freeze) |

---

## Open Questions (pending research)

- Do researchers work one-machine-per-project in practice? (Assumption — validate in researcher interviews; see Round 1 questions B5–B7 in the research guide.)
- Who owns the Teams destination for a project — researcher, project lead, IT? (Research question E16–18.)
- Does IT's machine-return process actually wipe the user account home folder, or only delete the account record? (Needs confirmation — belt-and-suspenders with Return Machine either way.)
- How does ARM know a channel was created less than 24 hours ago? Options: (a) store channel creation time in `state/app.json` when the researcher configures the destination; (b) query Graph for channel metadata at upload time. Option (a) is simpler and doesn't require an extra Graph call. Confirm preferred approach before implementing the 24-hour guard.
- Does ARM need to handle consent form upload separately, or is the consent channel configured independently by the study lead and ARM just needs to know its ID? Consent forms may not go through ARM at all — clarify with ResearchOps.
- The NAV routine says "filene slettes automatisk etter 8 måneder." Does ARM need to surface a warning in-app as the 8-month mark approaches for files already uploaded, or is the Teams/M365 notification sufficient? If ARM surfaces its own warning it needs to track `upload.completedAt` precisely.
