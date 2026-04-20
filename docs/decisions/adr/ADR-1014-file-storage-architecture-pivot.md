# ADR-1014: File Storage Architecture Pivot — Off Desktop, Into Application Support, Direct-to-Teams Upload

**Status**: Accepted (Planned — implementation pending Phase 0)

**Date**: 2026-04-14

**Deciders**: Fredrik Scheide, Claude (planning partner)

## Context

ARM currently stores all research data on the user's Desktop:

- Audio: `~/Desktop/lydfiler/<timestamp>.m4a`
- Transcripts: `~/Desktop/tekstfiler/<timestamp>.txt`
- Audit log: hidden dotfile inside the audio folder (`.audit_log.jsonl`)

Audio and transcripts are linked by **filename stem**, which breaks if a user renames a file in Finder. Egress to Teams/OneDrive today uses a manual "open Finder to the folder, let the user drag into the OneDrive-synced folder" flow via `uploadToTeams()` in [main.swift](../../../Sources/AudioRecordingManager/main.swift).

### Problem Statement

Three distinct problems converge on the same redesign:

1. **Compliance**: ARM captures sensitive research interviews with NAV service recipients and employees. Desktop placement on shared library machines means any future user of the same macOS account can see interview files. The current audit log is a user-editable dotfile, which fails tamper-evidence hygiene.
2. **Brittleness**: Filename-stem coupling breaks when users rename files. Metadata is scattered across filename, mtime, and a sidecar JSON that is not the source of truth.
3. **Egress reliability**: Manual "drag files into OneDrive folder" is error-prone: researchers forget files, drag to wrong folders, and the app has no trace of what was uploaded.

### Forces at Play

**Operational facts (confirmed with product owner, 2026-04-14):**
- Library machines are handed between researchers. Each researcher has a per-macOS-account roaming profile.
- Research is organised one-machine-per-project; researchers don't bounce between library machines mid-project.
- FileVault will be mandated on library machines.
- Egress destination is a **per-project shared Teams/SharePoint location** (not personal OneDrive).
- NAV has configured **30-day auto-deletion on OneDrive/Teams**. The 30-day window is by design: it is the time during which anonymization happens post-upload.
- Anonymization is done in a separate tool at a separate time by the researcher — it is **not** a pre-upload gate.
- Analysis is done in yet another tool, often weeks later.

**Constraints:**
- Files must not be visible to other users on shared library machines.
- Files must not reach non-ARM machines via roaming sync (the roaming profile would otherwise carry data to a researcher's other NAV-issued work Mac where ARM is not installed).
- Machines must be provably clean when returned to the library.
- Raw (un-anonymized) material will exist on OneDrive for up to 30 days — this is sanctioned, not a leak to prevent.

**Assumptions (load-bearing — must be confirmed before Phase 0F ships):**
- MDM (Jamf/Mosyle/similar) can exclude `~/Library/Application Support/AudioRecordingManager/` from the roaming profile sync. Confirmed by the mac-fleet owner. **If this assumption fails, this ADR must be revisited.**
- FileVault is actually mandated, not merely planned.
- Azure AD / Entra ID app registration with the required Graph scopes (`Files.ReadWrite`, `Sites.ReadWrite.All`, `User.Read`) will be granted.

## Decision

We pivot the file-storage architecture along four axes:

### 1. Storage location: Application Support, sync-excluded

All ARM data moves from `~/Desktop/{lydfiler,tekstfiler}/` to:

```
~/Library/Application Support/AudioRecordingManager/
  recordings/<uuid>/audio.m4a
  recordings/<uuid>/transcript.txt
  recordings/<uuid>/meta.json
  audit/audit-YYYY-MM.jsonl
  state/app.json
```

The mac-fleet admin configures MDM to exclude this path from the roaming profile sync. Files are then physically local to the library machine where they were produced.

### 2. On-disk identity: UUID folders, metadata in sidecars

Each recording is a directory named by UUID. Audio, transcript, and metadata live together. The human-readable label, timestamps, processing state, and upload state live in `meta.json`. The UI reads from the sidecar, never parses filenames. This kills the rename-breaks-link failure mode and makes atomic operations (move, delete, wipe) trivial.

### 3. Egress: direct Graph API upload to Teams/SharePoint

ARM uploads directly via Microsoft Graph to a pre-agreed Teams channel / SharePoint document library for the current project. Upload is **automatic per artifact** as each artifact reaches a stable final state (audio after recording stops; transcript after transcription completes). No manual file-selection UI. No folder picker per upload. No Finder drag step.

### 4. Local lifecycle: decoupled from upload, ended by Return Machine

Upload never triggers local deletion. Local files live as long as the researcher is using the machine. The **only** event that deletes local data is an explicit "Return Machine" flow:

1. Pre-check verifies all artifacts are confirmed uploaded via Graph API.
2. Friction gate requires the researcher to type a fixed phrase to unlock the wipe.
3. Secure delete (zero-overwrite + unlink) walks the entire ARM data root.
4. A receipt is written to `~/Documents/ARM_wipe_receipt_<timestamp>.txt` as an external audit trail.
5. Final audit entry is written, then the audit log itself is deleted.

There is no local 30-day cap. Retention is enforced on OneDrive by NAV's existing policy.

### Core Principles

1. **OS is the security boundary.** We rely on macOS per-user account isolation + FileVault + MDM-configured sync exclusion — not our own crypto. Simpler, auditable, testable.
2. **UUID on disk, labels in sidecar.** Filesystem names are opaque; the app is the source of truth for human-meaningful metadata.
3. **Upload and delete are independent lifecycles.** Local retention is driven only by explicit handoff, never by a background process.
4. **The app handles handoff, not IT.** Return Machine flow is belt-and-suspenders to IT account deprovisioning. Machine cleanliness is the researcher's responsibility, made easy and hard-to-skip by the app.

### Implementation Details

See [FILE_MANAGEMENT_AND_TEAMS_SYNC.md](../../FILE_MANAGEMENT_AND_TEAMS_SYNC.md) for the revised spec and [docs/prd/file-management-teams-sync/PHASE_0_TASKS.md](../../prd/file-management-teams-sync/PHASE_0_TASKS.md) for the build-order task list.

**Rollout phases:**

| Phase | Scope | Research dependency |
|-------|-------|---------------------|
| Phase 0 | Storage move + migration + Return Machine (upload verification stubbed) | None — safe to build now |
| Phase 1 | Azure AD app registration, Graph API upload, upload state tracking | Needs Teams destination answers |
| Phase 2 | Project concept, destination picker/config, UX tuned to research findings | Needs researcher interviews complete |

## Consequences

### Positive

- ✅ **Compliance posture improves materially.** Research recordings no longer sit on Desktop, accessible to any future user of a shared macOS account via casual snooping.
- ✅ **Machine-return wipe becomes enforceable.** The Return Machine flow provides a traceable end-of-project ritual that IT account deprovisioning can back up.
- ✅ **Audio-transcript coupling stops being fragile.** Rename-safe UUID identity replaces filename-stem matching.
- ✅ **Upload is deterministic and auditable.** Graph API uploads produce verifiable state; failed uploads are visible and retryable.
- ✅ **Desktop stops being a user-visible data store.** Researchers can't accidentally share files by email attachment, AirDrop, or screen-share of a cluttered Desktop.

### Negative

- ⚠️ **Depends on MDM sync exclusion working.** If the mac-fleet admin cannot exclude the ARM storage path from roaming sync, files will land on the researcher's other NAV-issued machines. This is the single largest risk in the plan.
- ⚠️ **Real work to rewire existing call sites.** Many files reference `~/Desktop/lydfiler/` paths directly. The refactor is mechanical but not small.
- ⚠️ **Azure AD app registration has long lead time.** Graph API integration blocks on NAV IT approval; this can take weeks.
- ⚠️ **Loss of Finder-visible files is a UX change researchers must adjust to.** Mitigation: ARM is the only sanctioned interface for these files anyway, by policy.
- ⚠️ **"One machine per project" is now a load-bearing assumption.** If researchers need to switch library machines mid-project, they lose access to local files (they'd have to re-download from OneDrive). Current workflow doesn't seem to require this, but if the research reveals otherwise, we revisit.

### Neutral

- 📊 **Retention responsibility shifts to OneDrive.** NAV already has a 30-day auto-delete policy on the destination. ARM does not enforce local retention; it enforces machine-cleanliness-on-handoff.
- 📊 **Anonymization stays out of ARM's critical path.** It's a post-upload workflow in a different tool. ARM does not gate on anonymization state.
- 📊 **Researchers can no longer inspect files with Finder.** They interact via ARM's UI only. Some will ask why; the compliance answer is clear.

## Alternatives Considered

### Alternative 1: Keep files on Desktop, add soft compliance guardrails

**Description**: Leave storage on Desktop. Add UI warnings, a "clean Desktop before handoff" button, stronger audit logging. Rely on researcher diligence.

**Rejected because**:
- ❌ Researcher diligence is not a compliance story that survives scrutiny.
- ❌ Desktop-visible files remain trivially shareable via email/AirDrop/screen share.
- ❌ Machines handed in with files still present is a real risk, not a hypothetical.

### Alternative 2: App-managed storage with our own at-rest encryption

**Description**: Store files in Application Support, accept that roaming sync copies them to other NAV machines, but encrypt at rest with a key scoped to the ARM app's signing identity. Other machines have the ciphertext but cannot satisfy the keychain ACL.

**Rejected because**:
- ❌ Adds real crypto complexity (key derivation, rotation, re-encrypt on migration, dev-build-vs-signed-release ACL issues) for a scenario that MDM sync exclusion solves more simply.
- ❌ Doubles the surface area we need to test for compliance.
- ✅ Remains the documented fallback if Alternative 1's MDM exclusion proves infeasible.

### Alternative 3: Upload-on-save with immediate local delete

**Description**: When a recording finishes, upload and delete locally. Machine is always maximally clean.

**Rejected because**:
- ❌ Ongoing work (transcription, analysis, re-listening) requires local copies. Forcing OneDrive round-trips every time degrades researcher experience catastrophically.
- ❌ Ties upload reliability directly to data retention — a failed upload becomes a data loss incident.
- ❌ Race conditions between processing and deletion (the problem that surfaced during discussion): deleting audio before transcription completes breaks transcription.

### Alternative 4: Force anonymization before upload

**Description**: Block upload until the researcher has anonymized the transcript in ARM.

**Rejected because**:
- ❌ Anonymization takes time. Blocking upload blocks machine handoff, which blocks the next researcher from using that machine. Breaks the library-sharing model entirely.
- ❌ NAV's 30-day OneDrive retention exists specifically to provide a post-upload anonymization window. Forcing pre-upload anonymization fights NAV's own design.

## Related Decisions

- ADR-1006: Network isolation default (still relevant — upload window is the only time network should be enabled)
- ADR-1007: NAV Design System integration (superseded by later Liquid Glass migration; audit log UI should follow current AppColors/AppSpacing conventions)

## References

- [FILE_MANAGEMENT_AND_TEAMS_SYNC.md](../../FILE_MANAGEMENT_AND_TEAMS_SYNC.md) — revised spec
- [docs/prd/file-management-teams-sync/USER_STORIES.md](../../prd/file-management-teams-sync/USER_STORIES.md) — user stories
- [docs/prd/file-management-teams-sync/PHASE_0_TASKS.md](../../prd/file-management-teams-sync/PHASE_0_TASKS.md) — Phase 0 build task list
- [Microsoft Graph — upload files to SharePoint](https://learn.microsoft.com/en-us/graph/api/driveitem-put-content)

## Revision History

- 2026-04-14: Initial decision (Accepted — Planned)
