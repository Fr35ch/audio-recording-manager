# User Stories: SD Card Import & DS2 Decryption

**Epic:** Olympus SD Card Import & Encrypted File Handling
**Date:** 2026-04-14 (revised 2026-04-20)
**Related:** [FILE_MANAGEMENT_AND_TEAMS_SYNC.md](../../FILE_MANAGEMENT_AND_TEAMS_SYNC.md), [ADR-1014](../../decisions/adr/ADR-1014-file-storage-architecture-pivot.md)
**Status:** Draft

---

## SD Card Detection & Import

### US-I1: Automatic SD card detection

**As a** researcher,
**I want** the app to automatically detect when I insert an SD card from my Olympus recorder,
**so that** I don't have to manually navigate to the card or configure anything.

#### Acceptance Criteria
- [ ] SD card insertion detected automatically via DiskArbitration framework
- [ ] Olympus-specific folder structures recognized (RECORDER, DSS_FLDR, DICT, OLYMPUS)
- [ ] Falls back to scanning for `.dss`/`.ds2` files if folder structure doesn't match
- [ ] Virtual devices, disk images, and iPhone AFC devices are excluded
- [ ] Detection banner shows: volume name, file count, eject button
- [ ] Card removal is detected and UI updates accordingly

**Status:** Not started

---

### US-I2: Browse and select files on SD card

**As a** researcher,
**I want to** see all audio files on the SD card and choose which ones to import,
**so that** I only import the recordings I need.

#### Acceptance Criteria
- [ ] All supported formats listed: m4a, mp3, wav, aiff, dss, ds2, mp4
- [ ] Recursive scan finds files in subfolders
- [ ] Each file shows: name, size (formatted), modification date
- [ ] Multi-select with "Select All" / "Deselect All"
- [ ] File count shown: "X of Y selected"
- [ ] Files sorted by modification date (newest first)

**Status:** Not started

---

### US-I3: Import selected files to secure storage

**As a** researcher,
**I want to** copy selected files from the SD card into ARM's secure storage,
**so that** I have the recordings locally and can work with them.

#### Acceptance Criteria
- [ ] Each imported file gets a new UUID recording folder under `~/Library/Application Support/AudioRecordingManager/recordings/<uuid>/`
- [ ] Audio saved as `audio.m4a` (or original extension) inside the UUID folder
- [ ] `meta.json` sidecar created with `displayName` = original filename stem, `createdAt` = file mtime
- [ ] Duplicate filenames are not a concern — UUID folders are always unique
- [ ] Progress bar shows import progress (X of Y files)
- [ ] Per-file errors are caught and logged without stopping the batch
- [ ] Success message shows total files imported
- [ ] Audit entry `recordingCreated` emitted for each imported file
- [ ] Files are **not** written to `~/Desktop/lydfiler/` or any Desktop path

**Status:** Needs reimplementation — original implementation used Desktop storage (superseded by Phase 0 storage architecture)

---

### US-I4: Choose to delete or keep files on SD card after import

**As a** researcher,
**I want to** be asked whether to delete the originals from the SD card after import,
**so that** I can free up space on the card or keep a backup.

#### Acceptance Criteria
- [ ] Prompt appears after successful import: "Delete imported files from SD card?"
- [ ] Options: Delete from SD card / Keep on SD card
- [ ] Only files that were successfully imported are eligible for deletion
- [ ] File verification before deletion (confirm copy is intact)
- [ ] Clear confirmation before destructive action
- [ ] SD card is not auto-ejected (user may want to import more)

**Status:** Not started

---

### US-I5: Safely eject SD card

**As a** researcher,
**I want to** eject the SD card from within the app,
**so that** I can safely remove it without switching to Finder.

#### Acceptance Criteria
- [ ] Eject button shown in SD card detection banner
- [ ] Uses `diskutil eject` for safe unmount
- [ ] UI updates to show card is removed
- [ ] Cannot eject during active import

**Status:** Not started

---

## DS2 Encrypted File Handling

### US-I6: Detect encrypted DS2 files

**As a** researcher,
**I want** the app to tell me which files on the SD card are encrypted,
**so that** I know which ones need decryption before they can be transcribed.

#### Acceptance Criteria
- [ ] DS2 files identified by magic bytes (`0x03ds2`)
- [ ] Encryption status detected from file header
- [ ] Encrypted files shown with a lock icon in the file list
- [ ] Non-encrypted audio files shown normally
- [ ] Mixed selection (encrypted + unencrypted) is allowed

**Status:** Not started

---

### US-I7: Store DS2 decryption password securely

**As a** researcher,
**I want to** enter my Olympus recorder password once and have it remembered securely,
**so that** I don't have to type it every time I import encrypted files.

#### Acceptance Criteria
- [ ] Password entry field shown when encrypted DS2 files are detected
- [ ] Password stored in macOS Keychain (`kSecAttrAccessibleWhenUnlocked`)
- [ ] Stored password used automatically for subsequent imports
- [ ] Option to update or remove stored password
- [ ] Password never written to disk outside Keychain

**Status:** Not started

---

### US-I8: Decrypt DS2 files during import

**As a** researcher,
**I want** encrypted DS2 files to be decrypted automatically during import,
**so that** they are ready for transcription without manual conversion steps.

#### Acceptance Criteria
- [ ] DS2 files decrypted using stored password during import
- [ ] Decrypted output saved as playable format (WAV or M4A) in `~/Desktop/lydfiler/`
- [ ] Original filename preserved with new extension
- [ ] Decryption progress shown per file
- [ ] Wrong password error is clear and allows retry
- [ ] Non-encrypted files imported normally (no decryption attempted)

**Status:** Not started (blocked — requires OM System Audio SDK or DSS Player license)

---

### US-I9: Fall back to DSS Player for decryption

**As a** researcher,
**I want** the app to guide me through using DSS Player to convert encrypted files,
**so that** I can still work with encrypted recordings even without automatic decryption.

#### Acceptance Criteria
- [ ] If automatic decryption is not available, app launches DSS Player with SD card path
- [ ] Clear instructions shown: "Convert your DS2 files to WAV in DSS Player, then import the converted files"
- [ ] App monitors `~/Desktop/lydfiler/` for new files (existing folder watcher)
- [ ] DSS Player detected by bundle ID (`com.olympus.DSSPlayerV7`) with fallback paths
- [ ] If DSS Player is not installed, show error with installation instructions

**Status:** Not started

---

### US-I10: Extract DS2 file metadata

**As a** researcher,
**I want to** see metadata from my Olympus recordings (duration, date, author, priority),
**so that** I can identify which recording is which before importing.

#### Acceptance Criteria
- [ ] DS2 header parsed for: duration, recording date, author, work type, priority, device info
- [ ] Metadata shown in file selection list alongside filename and size
- [ ] Priority flag (high/normal/low) shown if set on recorder
- [ ] Metadata extraction works even for encrypted files (header is not encrypted)

**Status:** Not started

---

## Priority Order

| Priority | Story | Status | Blocker |
|----------|-------|--------|---------|
| 1 | US-I1 | Not started | — |
| 2 | US-I2 | Not started | — |
| 3 | US-I3 | Not started | — |
| 4 | US-I5 | Not started | — |
| 5 | US-I4 | Not started | — |
| 6 | US-I6 | Not started | — |
| 7 | US-I7 | Not started | — |
| 8 | US-I9 | Not started | DSS Player license |
| 9 | US-I10 | Not started | — |
| 10 | US-I8 | Not started | OM System SDK or DSS Player license |
