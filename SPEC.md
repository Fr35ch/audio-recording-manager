# Virgin Project - Specifications

## Overview
**Purpose:**
A secure audio recording management application for researchers conducting audio recordings. The app manages the recording workflow on dedicated zero-trust Mac computers, ensuring network isolation during recording/import, and facilitating safe file management for transcription.

**Target Users:**
Researchers conducting audio recordings using either the native macOS Voice Memos app or external audio recorder devices (Olympus DS-9500).

**Environment:**
- Dedicated Mac computers configured as zero-trust machines
- Single-purpose machines used exclusively for audio recording/transcription
- VG JOJO Transcribe software installed and running alongside this app

---

## Features

### Core Features (Must Have)
- [x] Auto-launch on Mac startup
- [x] Automatic network/Bluetooth/AirDrop/external connections shutdown on launch
- [x] Initial screen with two options: "Record with Voice Recorder" OR "Import Audio from SD Card"
- [x] Launch native macOS Voice Memos app for recording (high quality)
- [x] Auto-detect SD card insertion for import workflow
- [x] User-selectable file import from SD card
- [x] Store imported/recorded files in ~/Desktop/lydfiler folder
- [x] Automatic file naming: "lydfil" + date/time stamp
- [x] Success message display after import/recording
- [x] Manual network override button to re-enable connections
- [x] "Upload to Teams" button that enables network, allows upload, then auto-disables network
- [x] User selects Teams destination folder each time
- [x] Prompt user to delete or keep files on SD card after import
- [x] App stays visible during use (doesn't minimize)

### Secondary Features (Should Have)
- [ ] File verification system to test files aren't corrupted before deleting originals from SD card
- [ ] Visual indicators for network/Bluetooth status (on/off)
- [ ] Upload progress indicator for Teams uploads
- [ ] Error handling and user-friendly error messages

### Future Features (Nice to Have)
- [ ] Integration with Olympus DS-9500 device (separate software integration)
- [ ] File integrity verification options (checksum, audio preview, format validation)
- [ ] Logging of all file operations for audit trail
- [ ] Batch import operations
- [ ] Export logs for troubleshooting

---

## User Interface

### Layout
**Main Screen (Launch):**
- Two large, clear buttons:
  - "Record with Voice Recorder"
  - "Import Audio from SD Card"
- Network status indicator
- Manual network override button (small, secondary)

**After Import/Recording:**
- Success message
- Return to main screen options

**Network Controls:**
- "Upload to Teams" button (enables network temporarily)
- Network status display
- Manual override button

### Design Style
- **Theme:** Clean, professional, minimal
- **Style:** Simple and functional (researchers need clarity, not decoration)
- **Priority:** Large, clear buttons for primary actions
- **Safety:** Clear visual feedback for network status (security critical)

### User Flow
1. **App launches on Mac startup** → Network/Bluetooth/AirDrop disabled automatically
2. **User sees main screen** → Choose "Record" or "Import"
3. **If Record:** Launch Voice Memos → User records → Files saved to ~/Desktop/lydfiler with timestamp
4. **If Import:** SD card detected → User selects files → Import to ~/Desktop/lydfiler → Verify files → Prompt to delete/keep originals
5. **Success message displayed** → Return to main screen
6. **When ready to upload:** Click "Upload to Teams" → Network enabled → User uploads → Network auto-disabled
7. **User drags files from ~/Desktop/lydfiler to VG JOJO Transcribe** (manual, outside this app)

---

## Technical Requirements

### Platform
- **Target OS:** macOS 13.0+
- **Framework:** SwiftUI
- **Language:** Swift 6.1+
- **Startup:** LaunchAgent configuration to auto-start on boot

### Data & Storage
- [x] Local file storage: ~/Desktop/lydfiler folder
- [ ] No database needed
- [ ] No cloud sync from within app (Teams upload is manual destination selection)
- [ ] No UserDefaults needed (single-purpose, no preferences)

### External Dependencies
- [x] System frameworks for network control (NetworkExtension or SystemConfiguration)
- [x] System frameworks for Bluetooth control (IOBluetooth)
- [x] System frameworks for SD card detection (DiskArbitration)
- [x] System frameworks for launching Voice Memos
- [x] VG JOJO Transcribe (separate app, launches at startup)
- [ ] Future: Olympus DS-9500 integration software

### System Permissions Required
- Network configuration access
- Bluetooth control
- Disk/USB device access
- File system access (Desktop folder)
- Launch applications permission

---

## Functional Requirements

### Main Functionality

**Network Security:**
- Disable WiFi, Bluetooth, AirDrop, and all external connections on app launch
- Provide manual override to temporarily enable network
- "Upload to Teams" workflow: enable → upload → auto-disable
- Visual status indicators for connection state

**Recording Workflow:**
- Launch native macOS Voice Memos app when "Record" selected
- Voice Memos must use high-quality recording settings
- Files automatically moved/copied to ~/Desktop/lydfiler with naming convention

**Import Workflow:**
- Auto-detect SD card insertion
- Display available files for user selection
- Import selected files to ~/Desktop/lydfiler
- Apply naming convention: lydfil_YYYYMMDD_HHMMSS
- Verify file integrity (TBD - method to be determined)
- Prompt: "Delete files from SD card?" with options: Delete / Keep

**File Management:**
- No file browser in app (users use Finder)
- Files stored in ~/Desktop/lydfiler
- Automatic timestamped naming
- Files manually dragged to VG JOJO Transcribe by user

### Edge Cases
- SD card removed during import → Cancel import, show error
- Network already enabled when app launches → Detect and offer to disable
- No SD card detected when "Import" selected → Show message to insert card
- Failed Teams upload → Keep network enabled, show error, let user retry
- Insufficient disk space → Warn before import
- Voice Memos app not available → Show error message
- Permission denied (network/Bluetooth control) → Show instructions to grant permissions

---

## Development Notes

### Implementation Priorities
1. **Phase 1 - Core Security & UI:**
   - Network/Bluetooth disable on launch
   - Main screen with Record/Import buttons
   - Basic file storage to ~/Desktop/lydfiler

2. **Phase 2 - Recording:**
   - Launch Voice Memos app
   - File naming with timestamps
   - Success messaging

3. **Phase 3 - SD Card Import:**
   - SD card detection
   - File selection UI
   - Import with naming
   - Delete/keep prompt

4. **Phase 4 - Network Controls:**
   - Manual override button
   - Upload to Teams workflow
   - Auto-disable after upload

5. **Phase 5 - File Verification:**
   - TBD: Determine best verification method
   - Implement chosen verification before SD card deletion

### Technical Constraints
- **Zero-trust environment:** Security is paramount
- **Single-user machines:** No multi-user considerations needed
- **No internet during normal operation:** App must function completely offline
- **macOS permissions:** Will require Full Disk Access, Network control permissions
- **Launch at startup:** Requires LaunchAgent configuration

### Security Considerations
- Network isolation is critical - must be bulletproof
- File verification before deletion (prevent data loss)
- Clear visual feedback for network state
- Permissions must be requested properly and validated

### References
- VG JOJO Transcribe: External transcription software
- Olympus DS-9500: External audio recorder device (future integration)
- Zero-trust Mac configuration documentation (to be provided)

---

## Agent Instructions

### When implementing:
- **Security first:** Network isolation is the highest priority feature
- **Clear error handling:** Researchers need clear, actionable error messages
- **Test permissions:** Ensure all required macOS permissions are properly requested
- **File safety:** Never delete original files without verification
- **Logging:** Consider adding logging for troubleshooting (security audit trail)
- **Code documentation:** Document security-critical sections thoroughly

### Key Considerations:
- This is a security-focused application for sensitive research data
- Users are researchers, not technical experts - UI must be simple and clear
- Machines are dedicated/single-purpose - no need for complex configuration
- Network must be disabled by default - this is a security requirement, not a feature
- File verification method needs to be determined before implementing SD card deletion
- Future Olympus DS-9500 integration will require separate software component

### Testing Requirements:
- Test on actual zero-trust configured Mac
- Verify network disable/enable cycles work correctly
- Test SD card detection and import with various card types
- Verify file naming consistency
- Test error conditions (no space, no permissions, etc.)
- Test with VG JOJO Transcribe running simultaneously

### Open Questions to Resolve:
1. **File verification method:** How to verify audio files aren't corrupted before allowing SD card deletion?
   - Options: Audio preview playback, checksum comparison, format validation, file size check
   - Decision needed before implementing Phase 5
