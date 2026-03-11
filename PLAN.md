# Integration Plan: Anonymization Service for ARM

**Date:** 4. mars 2026
**Feature:** Add no-anonymizer Python library integration to ARM (Audio Recording Manager)
**Status:** Awaiting confirmation before implementation

---

## 1. Codebase Analysis

### Current State

**Data Model:**
- `RecordingItem` struct: lightweight file metadata only (filename, path, date, size, duration)
- No database/persistence layer - all data is derived from filesystem
- No transcript storage or metadata persistence beyond file attributes

**Persistence Approach:**
- Pure file-based on `~/Desktop/lydfiler/`
- Each recording is a `.m4a` audio file
- No existing JSON metadata files or structured data storage

**Subprocess Pattern:**
- Existing code uses macOS `Process` class (Darwin.Foundation)
- Examples: `networksetup` calls in `NetworkManager`, `open -a` for JOJO Transcribe
- Pattern: create Process → set launchPath + arguments → waitUntilExit()

**Python Environment:**
- `pyproject.toml` exists but has no runtime dependencies yet
- No bundled Python or venv management currently
- Scripts directory exists for utilities (shell-based)

**UI Structure:**
- `RecordingView`: main recording interface (no detail view for transcripts yet)
- `AnonymizationReminderDialog` exists as placeholder - not connected
- No detail view showing individual recording metadata/transcript

**Audit Trail:**
- NOT implemented yet
- SPEC.md and BACKLOG.md mention it as planned feature
- No AuditLogger class exists

### Integration Points Found

1. **Recording Metadata**: Currently only file attributes loaded → need to add serialized JSON metadata files
2. **Subprocess Pattern**: `Process` class used extensively → follow this pattern for no-anonymizer calls
3. **Process Execution**: All background work should use `DispatchQueue.global()` → maintain main thread UI
4. **File Storage**: ~Desktop/lydfiler → each recording should have optional .metadata.json alongside audio
5. **Error Handling**: NAV design system (Norwegian UI/text) in place → use for error messages

---

## 2. Implementation Architecture

### 2.1 Data Model - RecordingItemExtended

**Problem:** `RecordingItem` is immutable struct loaded fresh from filesystem each time. Need to store:
- `originalTranscript: String` (immutable after import)
- `anonymizedTranscript: String?` (null until anonymization runs)
- `anonymizationDate: Date?`
- `anonymizationStats: [String: Int]?`

**Solution:** Create side-car metadata files

```
~/Desktop/lydfiler/
├── interview_20260304_120000.m4a
└── interview_20260304_120000.metadata.json  ← NEW
```

**metadata.json schema:**
```json
{
  "recordingId": "uuid-here",
  "originalTranscript": "Her sier respondenten at...",
  "anonymizedTranscript": "Her sier respondent P1 at...",
  "anonymizationDate": "2026-03-04T12:15:00Z",
  "anonymizationStats": {
    "person": 3,
    "phone_number": 1,
    "id_number": 1
  }
}
```

**Implementation:**
- Add `extension RecordingItem` with lazy-loaded metadata properties
- `RecordingMetadata` struct: encapsulates transcripts & anonymization data
- `RecordingMetadataManager`: handles JSON read/write

---

### 2.2 AnonymizationService - Python Bridge Layer

**File:** `Sources/AudioRecordingManager/AnonymizationService.swift`

**Architecture:**
1. Create temp file with transcript text
2. Call Python subprocess: `python3 -m no_anonymizer --input <tempfile> --output <outfile>`
3. Read JSON result from output file
4. Parse into Swift struct
5. Return results or throw error

**Key Design:**
- **Thread Safety**: All subprocess calls on `DispatchQueue.global(qos: .userInitiated)`
- **Timeout**: 30 seconds (NER model cold start can be slow)
- **Error Handling**: Catch SpaCy model missing gracefully
- **Result Struct**: Mirror Python `AnonymizationResult` exactly

```swift
struct AnonymizationResult: Codable {
    let anonymizedText: String
    let redactions: [Redaction]
    let stats: [String: Int]
    let processingTimeMs: Double

    struct Redaction: Codable {
        let position: Int
        let length: Int
        let category: String
        let replacement: String
    }
}

class AnonymizationService {
    static let shared = AnonymizationService()

    func anonymize(transcript: String) async throws -> AnonymizationResult {
        // Runs in background, publishes MainActor results
    }
}
```

**Error Cases:**
- SpaCy model not found → Show message: "Hent ned NLP-modell for anonymisering først" with instructions
- Timeout → "Anonymiseringseksporten tok for lang tid"
- Invalid JSON response → "Feil ved anonymisering"
- Process crash → "Anonymiseringstjenesten feilet"

---

### 2.3 Recording Detail View - New UI

**Currently Missing:** There's no detail view to show transcript + previous anonymization state

**Create:** `RecordingDetailView.swift`

**Sections:**
1. Recording info (duration, date, size)
2. Transcript section (editable - user can paste transcript)
3. Anonymization section (States A-D below)
4. Metadata history (when was it anonymized, previous stats)

**State A - Not Anonymized:**
```
┌─ Anonymisering av transkripsjon ────┐
│                                      │
│ [Anonymiser transkripsjon] button    │
│                                      │
│ Hva som fjernes:                     │
│ • Namen på personer                  │
│ • Kontaktoplysninger                 │
│ • Fødselsnumre                       │
└──────────────────────────────────────┘
```

**State B - In Progress:**
```
┌─ Anonymisering av transkripsjon ────┐
│                                      │
│ ◐ Anonymiserer...                   │
│                                      │
│ [Avbryt]                             │
│                                      │
│ ~80% prosessert                      │
└──────────────────────────────────────┘
```

**State C - Complete:**
```
┌─ Anonymisering av transkripsjon ────┐
│                                      │
│ ✓ Anonymisert 4. mar 12:15           │
│                                      │
│ Fjernet: 3 navn, 1 telefon, 1 fødsel │
│                                      │
│ [⊗ Original] [✓ Anonymisert]  ← toggle  │
│                                      │
│ [Kjør på nytt]                       │
└──────────────────────────────────────┘
```

**State D - Error:**
```
┌─ Anonymisering av transkripsjon ────┐
│                                      │
│ ⚠️  Feil ved anonymisering            │
│                                      │
│ "SpaCy modell ikke installert.       │
│  Kjør: python3 -m spacy download     │
│  nb_core_news_sm"                    │
│                                      │
│ [Prøv igjen]                         │
└──────────────────────────────────────┘
```

---

### 2.4 Audit Trail Extension

**Not Yet Implemented** - Create new file: `Sources/AudioRecordingManager/AuditLogger.swift`

**Design:**
- Append-only JSON log file: `~/Desktop/lydfiler/.audit_log.jsonl`
- One JSON object per line (JSONL format for easy streaming)
- Log only counts, timestamps, IDs - NOT actual text

**Audit Entry Schema:**
```json
{
  "timestamp": "2026-03-04T12:15:30.000Z",
  "recordingId": "uuid-here",
  "action": "anonymization_run",
  "stats": {"person": 3, "phone_number": 1},
  "processingTimeMs": 2450,
  "outcome": "success",
  "errorMessage": null
}
```

**Implementation:**
```swift
class AuditLogger {
    static let shared = AuditLogger()

    func logAnonymization(
        recordingId: String,
        stats: [String: Int],
        processingTimeMs: Double,
        outcome: AuditOutcome,
        error: String? = nil
    ) {
        // Append to JSONL file
    }
}

enum AuditOutcome: String, Codable {
    case success
    case error
}
```

**Access Control:**
- File restricted to user-read-only (no automatic export/sharing)
- Never logged to system Console.app
- Only accessible via Files app > lydfiler folder

---

### 2.5 Python Dependency Installation

**Current State:** pyproject.toml has no runtime dependencies

**Changes to Make:**

1. **Update pyproject.toml:**
   ```toml
   dependencies = [
       "no-anonymizer @ git+https://github.com/[your-org]/no-anonymizer.git",
       "spacy>=3.7.0",
   ]
   ```

2. **Create First-Run Setup:**
   - Detect if `no-anonymizer` module is installed
   - If missing, show dialog: "Anonymiseringstjenesten kreves. Installer fra Terminal:"
   - Show command: `pip install git+https://github.com/[your-org]/no-anonymizer.git`
   - Check if SpaCy model is available
   - If missing, show: `python3 -m spacy download nb_core_news_sm`

3. **Bundling Strategy (Future):**
   - For distribution, app can bundle Python + venv via PyInstaller
   - Not required for development/testing

---

## 3. Implementation Order

### Phase 1: Core Data Model & Service
1. **RecordingMetadata.swift** - Data structures for transcript storage
2. **RecordingMetadataManager.swift** - JSON read/write alongside .m4a files
3. **AnonymizationService.swift** - Python subprocess bridge (with mocked test)
4. **Integration test**: Save metadata, read it back, verify persistence

### Phase 2: UI & Recording Detail
5. Create **RecordingDetailView.swift** component
6. Add button to open detail view from recording list
7. Implement States A-D in detail view
8. Wire UI to AnonymizationService

### Phase 3: Audit & Polish
9. **AuditLogger.swift** - JSONL logging
10. Test full flow: tap button → anonymize → log → verify
11. Update README with first-run setup instructions

### Phase 4: Error Handling & Norwegian Text
12. All error messages in Norwegian (currently in plan)
13. Graceful fallback if Python missing
14. Thread safety testing (UI doesn't block)

---

## 4. File Structure & Changes

### New Files
```
Sources/AudioRecordingManager/
├── AnonymizationService.swift          ← NEW
├── RecordingMetadata.swift             ← NEW
├── RecordingMetadataManager.swift      ← NEW
├── AuditLogger.swift                   ← NEW
├── RecordingDetailView.swift           ← NEW
└── main.swift                          ← MODIFY (add detail view integration)
```

### Modified Files
- `pyproject.toml` - Add `no-anonymizer` dependency
- `main.swift` - Import new modules, add detail view sheet
- `README.md` - Document setup & SpaCy model download

### Data Files Created at Runtime
```
~/Desktop/lydfiler/
├── interview_20260304_120000.m4a
├── interview_20260304_120000.metadata.json  ← NEW
└── .audit_log.jsonl                         ← NEW (append-only)
```

---

## 5. Strict Rules - Implementation Checklist

- [ ] `originalTranscript` is **immutable** after first import - no code path overwrites it
- [ ] Anonymization only overwrites `anonymizedTranscript`, never `originalTranscript`
- [ ] ALL Python subprocess calls run on `DispatchQueue.global()` - never main thread
- [ ] UI never blocks during anonymization - use @State + async/await properly
- [ ] All error messages in Norwegian (NAV terminology)
- [ ] Audit log records only counts, IDs, timestamps - never actual text
- [ ] Follow existing `Process`-based pattern exactly - no new patterns
- [ ] RecordingMetadata persists to disk immediately after changes
- [ ] No database - stay with file-based storage
- [ ] 30-second timeout on Python subprocess
- [ ] Graceful handling if SpaCy model not installed

---

## 6. Norwegian UI Text Reference

| Feature | Norwegian |
|---------|-----------|
| Main button | "Anonymiser transkripsjon" |
| In progress | "Anonymiserer..." |
| Completed | "Anonymisert [dato]" |
| Redaction summary | "3 navn, 1 telefonnummer, 1 fødselsnummer fjernet" |
| Re-run button | "Kjør på nytt" |
| SpaCy missing | "Hent ned NLP-modell for anonymisering først" |
| Toggle original | "Original" |
| Toggle anonymized | "Anonymisert" |
| Error title | "Feil ved anonymisering" |
| Retry button | "Prøv igjen" |

---

## 7. Testing Strategy

### Unit Tests
- `AnonymizationService` with mocked Python subprocess
- `RecordingMetadataManager` JSON read/write
- `AuditLogger` JSONL append

### Integration Tests
1. Record audio → name → save
2. Load metadata from disk
3. Tap "Anonymiser" button → runs Python
4. Verify both original and anonymized texts saved
5. Verify audit log entry created
6. Toggle between original/anonymized views

### Manual Testing
1. **Happy path**: Full flow button → complete
2. **SpaCy missing**: Show help text
3. **Timeout**: 31+ second mock response → timeout error
4. **No network required**: Verify works offline
5. **UI responsiveness**: Progress indicator updates smoothly

---

## 8. Known Dependencies & Constraints

**External:**
- `no-anonymizer` Python library (from GitHub)
- SpaCy NLP library (`spacy>=3.7.0`)
- Norwegian language model (`nb_core_news_sm`)

**Internal:**
- `Process` (Darwin/Foundation) - already available
- `DispatchQueue` (Foundation) - already available
- NAV colors/design system - already defined

**Python Compatibility:**
- Python 3.9+ (already required by project)
- macOS 14+ (Sonoma/Sequoia) - already required

---

## 9. Not Building (Out of Scope)

- ❌ Automatic background anonymization
- ❌ Batch anonymization across multiple recordings
- ❌ Changes to transcription pipeline
- ❌ New persistence patterns (staying file-based)
- ❌ Web UI or cloud sync
- ❌ Mobile apps

---

## Summary

This plan integrates `no-anonymizer` as a Swift-Python bridge following ARM's existing patterns:
1. File-based metadata storage (like .m4a files)
2. Process-based subprocess execution (like networksetup calls)
3. NAV design + Norwegian UI
4. Immutable original, mutable anonymized (one-way flow)
5. Audit trail for security compliance
6. All work on background threads, zero UI blocking

**Next Step:** Wait for confirmation before implementing phases 1-2.
