# User Stories: Anonymization

**Epic:** Transcript Anonymization
**Date:** 2026-04-14
**Status:** Draft

---

## US-A1: Anonymize a transcript automatically

**As a** researcher,
**I want to** run automatic anonymization on my transcript,
**so that** personal data (names, phone numbers, SSNs) is redacted before I share or upload the text.

### Acceptance Criteria
- [ ] "Anonymiser transkripsjon" button available when a transcript exists
- [ ] Runs no-anonymizer Python library via subprocess bridge
- [ ] Detects and redacts: person names (NAVN), phone numbers (TELEFON), SSNs (FØDSELSNUMMER), D-numbers (D-NUMMER), email addresses (EPOST), organizations (ORG), place names (STED)
- [ ] Replaces identified entities with codes (e.g., P1, P2)
- [ ] Result stored atomically to `StorageLayout.anonymizedTranscriptURL(id: recordingId)`
- [ ] Metadata sidecar (`meta.json`) updated with `anonymization.completedAt` and `anonymization.stats`
- [ ] Original transcript is never modified (immutability guarantee)
- [ ] Timeout: 180 seconds

---

## US-A2: Understand anonymization limitations before running

**As a** researcher,
**I want to** be informed about what automatic anonymization can and cannot detect,
**so that** I understand my responsibility to manually review the result.

### Acceptance Criteria
- [ ] Informed consent modal shown before anonymization runs
- [ ] Lists what IS detected (names, phone numbers, SSNs, email)
- [ ] Lists what IS NOT detected (indirect identifiers, nicknames, geographic proximity, incomplete info)
- [ ] Warning: "Automatisk anonymisering er ikke tilstrekkelig alene"
- [ ] Checkbox: "Jeg forstår at teksten må kontrolleres manuelt" (must be checked to proceed)
- [ ] Same modal used for both recording detail and transcript detail views

---

## US-A3: Compare original and anonymized text

**As a** researcher,
**I want to** switch between the original and anonymized versions of my transcript,
**so that** I can verify the anonymization was done correctly.

### Acceptance Criteria
- [ ] Toggle/segmented picker: "Original" vs "Anonymisert"
- [ ] Both versions displayed in the same view for easy comparison
- [ ] Anonymized version shows redacted text inline
- [ ] Anonymization date and statistics shown (e.g., "3 navn, 1 telefonnummer fjernet")

---

## US-A4: Re-run anonymization

**As a** researcher,
**I want to** re-run anonymization on a transcript,
**so that** I can get updated results if the anonymization model has been improved.

### Acceptance Criteria
- [ ] "Kjør på nytt" button available after initial anonymization
- [ ] Re-run overwrites previous anonymized text in metadata
- [ ] Original transcript remains untouched
- [ ] New anonymization date and stats are recorded

---

## US-A5: See anonymization status across all transcripts

**As a** researcher,
**I want to** see at a glance which transcripts have been anonymized,
**so that** I know which ones are ready to share and which still need processing.

### Acceptance Criteria
- [ ] Transcript list shows icon per entry: shield (anonymized) vs doc (not anonymized)
- [ ] Status derived from metadata sidecar (`anonymizedTranscript != nil`)
- [ ] Status updates automatically when anonymization completes

---

## US-A6: Audit trail for anonymization

**As a** researcher (and for compliance),
**I want** all anonymization activity to be logged,
**so that** there is a traceable record for data protection compliance.

### Acceptance Criteria
- [ ] Audit log entry on every anonymization attempt (success or failure)
- [ ] Entry includes: timestamp, recording ID, action, stats (counts only, no text), processing time, outcome
- [ ] Logged via `AuditLogger` to `~/Library/Application Support/AudioRecordingManager/audit/audit-YYYY-MM.jsonl`
- [ ] Error details included for failed attempts
- [ ] Log never contains actual transcript text (privacy)

---

## US-A7: Anonymization check before upload

**As a** researcher,
**I want to** be reminded to check anonymization before uploading files to Teams,
**so that** I don't accidentally share files containing personal data.

### Acceptance Criteria
- [ ] Anonymization reminder dialog shown before any upload flow
- [ ] Checklist: remove names, contact info, ID numbers, health information
- [ ] Instruction to use codes (P1, P2) instead of names
- [ ] Must confirm checklist before proceeding to upload
- [ ] Files marked "not anonymized" show warning icon in file selection

**Note:** The pre-upload compliance acknowledgement gate is specified in [US-FM-15](../file-management-teams-sync/USER_STORIES.md#us-fm-15-i-confirm-compliance-requirements-before-my-first-upload). US-A7 covers the per-recording anonymization reminder; US-FM-15 covers the project-level compliance checklist. Both apply.

---

## Priority Order

| Priority | Story | Status |
|----------|-------|--------|
| 1 | US-A1 | Not started |
| 2 | US-A2 | Not started |
| 3 | US-A3 | Not started |
| 4 | US-A7 | Not started |
| 5 | US-A5 | Not started |
| 6 | US-A6 | Not started |
| 7 | US-A4 | Not started |
