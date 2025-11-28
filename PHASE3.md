# Phase 3: SD Card Import - Project Plan

## Overview
This phase implements SD card auto-detection and file import functionality for the Virgin Project audio recording manager.

## Status: PENDING
**Started:** TBD
**Completed:** TBD
**Estimated Time:** 2-3 development sessions

---

## Goals

Enable researchers to:
1. Insert an SD card and have the app automatically detect it
2. Browse and select specific audio files from the SD card
3. Import selected files to ~/Desktop/lydfiler with automatic naming
4. Verify file integrity before allowing deletion of originals
5. Choose to keep or delete files from the SD card after import

---

## Task Breakdown

### 1. SD Card Detection (Tasks 1-2)
**Priority:** HIGH
**Dependencies:** None

- [ ] Research DiskArbitration framework API
- [ ] Implement disk monitoring service
- [ ] Detect when SD card is inserted
- [ ] Detect when SD card is removed
- [ ] Get mount path of SD card
- [ ] Test with actual SD card hardware

**Technical Notes:**
- Use `DiskArbitration` framework (already imported)
- Register callback for disk appearance/disappearance
- Store SD card mount path for file operations

---

### 2. File Browser UI (Tasks 3-4)
**Priority:** HIGH
**Dependencies:** SD Card Detection

- [ ] Design file list view in SwiftUI
- [ ] Display files from SD card mount path
- [ ] Filter for audio file types (.m4a, .mp3, .wav, .aiff, etc.)
- [ ] Show file name, size, and date
- [ ] Add multi-select checkboxes for each file
- [ ] Add "Select All" / "Deselect All" buttons
- [ ] Show selected file count and total size

**UI Mockup:**
```
┌─────────────────────────────────────┐
│  Files on SD Card (5 files, 125MB) │
├─────────────────────────────────────┤
│ [x] audio_001.m4a    25MB  14:30    │
│ [ ] audio_002.m4a    30MB  14:45    │
│ [x] audio_003.m4a    20MB  15:00    │
│ [ ] audio_004.m4a    25MB  15:15    │
│ [x] audio_005.m4a    25MB  15:30    │
├─────────────────────────────────────┤
│ [Select All] [Deselect All]         │
│           [Import Selected (3)]     │
└─────────────────────────────────────┘
```

---

### 3. File Import (Tasks 5-6)
**Priority:** HIGH
**Dependencies:** File Browser UI

- [ ] Copy selected files from SD card to ~/Desktop/lydfiler
- [ ] Rename files with naming convention: lydfil_YYYYMMDD_HHMMSS
- [ ] Handle filename conflicts (add sequence number if needed)
- [ ] Show progress indicator during import
- [ ] Display success message with count of imported files
- [ ] Handle import cancellation

**Naming Convention:**
- Format: `lydfil_YYYYMMDD_HHMMSS.ext`
- Example: `lydfil_20251115_143052.m4a`
- If conflict: `lydfil_20251115_143052_2.m4a`

---

### 4. File Verification (Task 7)
**Priority:** MEDIUM
**Dependencies:** File Import
**Status:** ⚠️ METHOD TO BE DETERMINED

**Options to Discuss:**

**Option A: Simple File Checks (Fast)**
- Verify file size matches
- Check file format/header is valid
- Confirm file is readable

**Option B: Audio Preview (User-Friendly)**
- Play first 3-5 seconds of audio
- User confirms it plays correctly
- More time-consuming but thorough

**Option C: Checksum Comparison (Technical)**
- Calculate MD5/SHA256 before and after copy
- 100% accurate but slower
- No user interaction needed

**Option D: Hybrid Approach (Recommended)**
- Automatic: File size + format validation
- Optional: Audio preview for user verification
- Best balance of speed and reliability

**Decision Needed:** Which method should we implement?

---

### 5. Delete/Keep Prompt (Task 8)
**Priority:** HIGH
**Dependencies:** File Verification

- [ ] Show dialog after successful import
- [ ] Display verification results
- [ ] Offer "Delete from SD Card" or "Keep on SD Card" options
- [ ] Implement safe deletion (move to trash, not permanent delete)
- [ ] Show confirmation of action taken

**Dialog Mockup:**
```
┌──────────────────────────────────────┐
│  Import Successful                   │
├──────────────────────────────────────┤
│  3 files imported successfully       │
│  All files verified                  │
│                                      │
│  Delete originals from SD card?     │
│                                      │
│  [Keep on SD Card]  [Delete Files]  │
└──────────────────────────────────────┘
```

---

### 6. Edge Cases & Error Handling (Tasks 9-11)
**Priority:** MEDIUM
**Dependencies:** Core functionality complete

**SD Card Removed During Import:**
- [ ] Detect disconnection mid-import
- [ ] Cancel ongoing operations
- [ ] Show error message
- [ ] Keep already-imported files
- [ ] Log which files failed

**Insufficient Disk Space:**
- [ ] Check available space before import
- [ ] Calculate total size of selected files
- [ ] Warn user if insufficient space
- [ ] Prevent import if not enough room

**Corrupted/Unreadable Files:**
- [ ] Try to read file before importing
- [ ] Skip corrupted files with warning
- [ ] Continue with other files
- [ ] Report which files failed

---

### 7. Testing (Task 12)
**Priority:** HIGH
**Dependencies:** All features implemented

**Test Scenarios:**
- [ ] Insert SD card - app detects it
- [ ] Remove SD card - app handles gracefully
- [ ] Import single file
- [ ] Import multiple files
- [ ] Import all files
- [ ] Cancel import mid-way
- [ ] Remove SD card during import
- [ ] Full disk scenario
- [ ] Corrupted file handling
- [ ] Very large files (>1GB)
- [ ] Many small files (>100)
- [ ] Different audio formats (.m4a, .mp3, .wav)
- [ ] Files with special characters in names

**Hardware Testing:**
- [ ] Test with multiple SD card brands
- [ ] Test with different card sizes (8GB, 16GB, 32GB+)
- [ ] Test with Olympus DS-9500 files specifically

---

### 8. Documentation (Tasks 13-14)
**Priority:** MEDIUM
**Dependencies:** Testing complete

- [ ] Update SPEC.md Phase 3 status to "IMPLEMENTED"
- [ ] Add SD card import section to README.md
- [ ] Document supported file formats
- [ ] Add troubleshooting section
- [ ] Include screenshots of import workflow
- [ ] Update agent commands if needed

---

## Technical Architecture

### Components to Create:

1. **SDCardManager.swift** (new file)
   - DiskArbitration monitoring
   - SD card detection and mounting
   - File listing from SD card

2. **FileImporter.swift** (new file)
   - File copy operations
   - Progress tracking
   - Naming convention application
   - Verification logic

3. **ImportView.swift** (new file)
   - File browser UI
   - Selection controls
   - Import progress display
   - Delete/Keep dialog

4. **Update main.swift**
   - Connect importFromSDCard() to ImportView
   - Handle SD card insertion notifications
   - Show import UI when SD card detected

### File Structure:
```
Sources/VirginProject/
├── main.swift                  (existing - update)
├── SVGImageView.swift         (existing)
├── SDCardManager.swift        (new - SD card detection)
├── FileImporter.swift         (new - import logic)
└── ImportView.swift           (new - import UI)
```

---

## Integration Points

### With Existing Features:
- **Demo Mode:** SD card detection should work in demo mode
- **Network Status:** No network needed for import (stays disabled)
- **File Manager:** Use existing AudioFileManager for destination
- **Success Messages:** Use existing success message system

### With Future Phases:
- **Phase 4:** Network controls remain unchanged
- **Phase 5:** File verification system will be expanded

---

## Security Considerations

- Files imported while network is disabled (security maintained)
- No external connections during SD card operations
- Files only copied to approved location (~/Desktop/lydfiler)
- Original files only deleted after user confirmation
- Verification ensures data integrity

---

## User Experience Flow

1. **User inserts SD card**
   - App automatically detects insertion
   - Shows notification: "SD card detected"
   - "Import from SD Card" button highlights or auto-opens import view

2. **User views files**
   - File list appears showing all audio files
   - File details (name, size, date) displayed
   - Select individual files or "Select All"

3. **User imports files**
   - Clicks "Import Selected"
   - Progress bar shows import status
   - Files copied and renamed automatically

4. **User verifies files**
   - Verification runs automatically
   - Results shown to user
   - Option to preview if implemented

5. **User decides on originals**
   - Dialog asks: Keep or Delete?
   - User chooses action
   - Confirmation message shown

6. **Import complete**
   - Success message displays
   - Returns to main view
   - Files ready in ~/Desktop/lydfiler

---

## Open Questions

1. **File Verification Method:** Which approach? (See Task 7 above)

2. **Auto-Open Import View:** Should the import view automatically open when SD card is detected, or just highlight the button?

3. **File Format Support:** Which audio formats should we support?
   - Required: .m4a (Voice Memos), .mp3 (Olympus)
   - Nice to have: .wav, .aiff, .mp4, .ogg?

4. **File Conflicts:** If file with same timestamp exists, what should we do?
   - Add sequence number (recommended)
   - Skip file
   - Prompt user

5. **Import Location:** Always ~/Desktop/lydfiler or allow user to choose?
   - Current spec: Always ~/Desktop/lydfiler
   - Do we need flexibility?

---

## Success Criteria

Phase 3 is complete when:
- ✅ SD card insertion is automatically detected
- ✅ Files can be browsed and selected
- ✅ Selected files import successfully with correct naming
- ✅ File verification confirms integrity
- ✅ User can safely delete or keep originals
- ✅ All edge cases handled gracefully
- ✅ Tested with actual hardware
- ✅ Documentation updated
- ✅ No regressions in Phases 1 & 2

---

## Notes

- **Hardware Needed:** SD card reader and SD cards for testing
- **Olympus DS-9500:** Phase 3 should work with files from this device
- **Zero-Trust:** Import must work without network access
- **User Type:** Researchers (non-technical) - UI must be simple and clear

---

## References

- SPEC.md - Full project specifications
- README.md - User documentation
- Apple DiskArbitration Framework Documentation
- SwiftUI FileManager API

---

**Last Updated:** 2025-11-15
**Status:** Ready to begin
