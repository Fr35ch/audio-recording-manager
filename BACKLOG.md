# Product Backlog

This document tracks planned features, ongoing investigations, and future work for the Virgin Project - Audio Recording Manager.

**Last Updated:** 2026-04-14
**Project Manager:** Claude Code

## PM Guidelines

**Model Usage:**
- PM tasks (documentation, backlog updates, changelog edits): Use **Haiku model** to reduce token costs
- Technical implementation tasks: Use appropriate model based on complexity
- Complex investigations or architecture decisions: Use Sonnet/Opus as needed

---

## Current Sprint

### 🟢 ACTIVE — File Management Architecture Pivot (Phase 0)

**Epic:** File Management & Teams Sync (revised)
**Priority:** High
**Status:** Planned and scoped — ready to build
**Decision:** [ADR-1014](docs/decisions/adr/ADR-1014-file-storage-architecture-pivot.md)
**Spec:** [docs/FILE_MANAGEMENT_AND_TEAMS_SYNC.md](docs/FILE_MANAGEMENT_AND_TEAMS_SYNC.md)
**Stories:** [docs/prd/file-management-teams-sync/USER_STORIES.md](docs/prd/file-management-teams-sync/USER_STORIES.md)
**Tasks:** [docs/prd/file-management-teams-sync/PHASE_0_TASKS.md](docs/prd/file-management-teams-sync/PHASE_0_TASKS.md)

Moves storage off the Desktop and into `~/Library/Application Support/`, switches to UUID-named recording folders with sidecar metadata, relocates the audit log, and introduces the Return Machine wipe flow. Phase 1 (Graph API upload to Teams/SharePoint) follows, blocked on Azure AD app registration.

**Parallel external-dependency tracks (kicked off 2026-04-14):**
- MDM sync exclusion for `~/Library/Application Support/AudioRecordingManager/` — mac-fleet admin
- FileVault mandate confirmation on library machines — NAV IT
- Azure AD / Entra ID app registration — NAV IT (long lead time, blocks Phase 1)

**Parallel research track:**
- Researcher discovery interviews — product owner conducting. Blocks Phase 2 (project concept, destination picker UX). See interview guide prepared in the planning conversation.

---

### 🔴 BLOCKED - Awaiting DSS Player License

**Epic: Encrypted DS2 File Support**
**Priority:** High
**Status:** Blocked - DSS Player for Mac installed, awaiting license purchase

---

## Active Investigations

### Investigation: Encrypted Audio File Workflow
**Started:** 2025-11-16
**Updated:** 2025-11-24
**Status:** BLOCKED - Awaiting DSS Player for Mac license purchase

#### Context
All audio files from the Olympus DS-9500 recorder are password-protected using 256-bit AES encryption. Current workflow cannot handle these files as Jojo Transcribe cannot open encrypted DS2 files directly.

#### Current Status (2025-11-24)
- ✅ DS2 test files available on SD card
- ✅ DSS Player for Mac v7 installed
- 🔴 **BLOCKED:** Need to purchase DSS Player license
- ⚠️ DSS Player for Mac support ends March 31, 2025

#### Key Findings

**DSS Player (v7.7.8):**
- Required for decryption - no SDK/API available
- Bundle ID: `com.olympus.DSSPlayerV7`
- Supported formats: DS2 (encrypted), DSS Classic
- Can convert to: AIFF, WAV, MP3
- No command-line tools or automation API
- Limited AppleScript support

**Jojo Transcribe (v1.7):**
- Bundle ID: `no.vg.jojo`
- Has macOS Service: "Transcribe with Jojo"
- Accepts `public.file-url` (can receive files programmatically)
- Unknown audio format support (needs testing)

**Current Workflow Gap:**
1. Audio Manager copies DS2 files to `~/Desktop/lydfiler`
2. ❌ Files are encrypted - Jojo cannot open them
3. ❌ Manual DSS Player step required for decryption

#### Tasks

- [x] ~~Obtain encrypted DS2 test file from Olympus DS-9500~~ (Available on SD card)
- [x] ~~Install DSS Player for Mac~~ (Installed, awaiting license)
- [ ] **BLOCKED:** Purchase DSS Player for Mac license (~$100-150)
- [ ] Activate DSS Player with license key
- [ ] Test DSS Player with encrypted DS2 files
  - [ ] Test single file decryption/playback
  - [ ] Test file conversion to AIFF/WAV
  - [ ] Test auto-conversion folder monitoring feature
  - [ ] Document password entry workflow
- [ ] Test what audio formats Jojo accepts (WAV, M4A, AIFF, MP3)
- [ ] Determine optimal workflow (manual, semi-auto, or guided)
- [ ] Implement chosen workflow in Virgin Project

#### Workflow Options Under Consideration

**Option 1: Full UI Automation**
- Use macOS Accessibility API to control DSS Player
- Fully automated but complex to implement
- May be fragile with DSS Player updates

**Option 2: Guided Semi-Automated**
- Audio Manager copies files
- App pauses and prompts user to convert in DSS Player
- App detects when conversion is complete and continues
- Balanced approach - some automation, some manual steps

**Option 3: Manual Process**
- Document clear workflow instructions
- User handles DSS Player manually
- Audio Manager focuses on other automation
- Simplest to implement, least automated

#### Technical Constraints
- No DSS Player SDK/API available
- No command-line conversion tools
- AppleScript support is minimal
- Must maintain security (network isolation)

#### Success Criteria
- [ ] Encrypted DS2 files can be processed into format Jojo accepts
- [ ] Workflow is documented and repeatable
- [ ] User experience is clear and simple
- [ ] Network isolation is maintained during file operations

---

## Planned Features (Phase 3+)

### Phase 3: SD Card Import & Olympus Integration

**Status:** Planning

#### Features
- [ ] SD card auto-detection when inserted
- [ ] Import audio files from SD card to `~/Desktop/lydfiler`
- [ ] File verification before deleting originals from SD card
- [ ] Olympus DS-9500 device integration
- [ ] Handle encrypted DS2 files (see investigation above)

#### Technical Requirements
- SD card detection using DiskArbitration framework (already included)
- File integrity verification (checksums)
- Safe delete with confirmation

---

### Phase 4: Network Controls Enhancement

**Status:** Backlog

#### Features
- [ ] Upload progress tracking
- [ ] Network enable/disable automation improvements
- [ ] Better visual feedback for network operations
- [ ] Upload verification

---

### Phase 5: File Verification & Security

**Status:** Backlog

#### Features
- [ ] Audio file integrity verification
- [ ] Audit logging for file operations
- [ ] Secure file deletion options
- [ ] Backup management

---

### Phase 6: UI/UX Design Review & Redesign

**Status:** Backlog
**Priority:** Medium

#### Objective
Review and redesign all UI components to align with NAV Design System (Aksel) for improved consistency, accessibility, and user experience.

#### Features
- [ ] Audit current UI components and design patterns
- [ ] Review NAV Design System documentation at nav.aksel.no
- [ ] Identify components that can be aligned with NAV design patterns
- [ ] Create UI component inventory
- [ ] Design mockups aligned with NAV design principles
- [ ] Implement redesigned components
- [ ] Update color scheme and typography to match NAV standards
- [ ] Improve accessibility (WCAG compliance)
- [ ] Test with researchers for usability

#### Resources
- NAV Design System: https://aksel.nav.no
- Current UI: SwiftUI-based macOS application

#### Benefits
- Improved visual consistency
- Better accessibility
- Professional, polished appearance
- Alignment with Norwegian design standards
- Enhanced user experience for researchers

---

## Research Needed

### Jojo Transcribe Audio Format Support
- [ ] Test WAV file support
- [ ] Test M4A file support
- [ ] Test AIFF file support
- [ ] Test MP3 file support
- [ ] Document optimal format for transcription quality

### DSS Player Automation
- [ ] Research macOS Accessibility API for UI automation
- [ ] Test AppleScript capabilities in depth
- [ ] Check for third-party DS2 decryption libraries
- [ ] Investigate Automator workflow possibilities

---

## Technical Debt

None currently tracked.

---

## Ideas / Future Considerations

- Integration with other transcription services
- Cloud backup options (with network controls)
- Multi-language support
- Voice command controls
- Batch transcription queue management

---

## Notes

**File Locations:**
- Audio storage: `~/Desktop/lydfiler`
- DSS Player: `/Applications/DSS Player/DSS Player.app`
- Jojo Transcribe: `/Applications/Jojo.app`

**Security Requirements:**
- Network isolation must be maintained during normal operation
- All file operations should work offline
- Administrator privileges required for network controls
