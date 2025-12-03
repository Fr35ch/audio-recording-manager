# Changelog

≈All notable changes to the Audio Recording Manager (ARM) will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### In Progress
- Encrypted DS2 file support investigation (see BACKLOG.md)
- SD card auto-detection and import functionality (Phase 3)
- Olympus DS-9500 device integration

### Changed - 2025-11-27
- **Migrated to NavigationSplitView architecture** ✅ IMPLEMENTED
  - Replaced custom sidebar implementation with native NavigationSplitView
  - Improved sidebar toggle animation and column visibility management
  - Added flexible sidebar width (min: 250pt, ideal: 300pt, max: 400pt)
  - Fixed rendering artifacts during sidebar animations
  - Removed duplicate toggle buttons (using native split view controls)

- **Updated deployment target to macOS 15.0+ (Sequoia)** ✅ IMPLEMENTED
  - Updated LSMinimumSystemVersion in Info.plist to 15.0
  - Added `-target arm64-apple-macos15.0` to build configuration
  - Ensures compatibility with latest SwiftUI features and APIs
  - Better animation performance and rendering with Sequoia SDK

- **UI/UX improvements** ✅ IMPLEMENTED
  - Applied white background theme across all views
  - Removed toolbar separator line for cleaner appearance
  - Fixed double-animation issues in content area
  - Improved overall visual consistency

### Fixed - 2025-11-24
- **Fixed false positive SD card detection - PKG/DMG installers no longer detected** ✅ TESTED
  - Issue: All mounted volumes (PKG installers, DMG files) were incorrectly detected as SD cards
  - Root cause: Insufficient filtering allowed disk images to pass validation
  - **Solution implemented:**
    - Added read-only volume check (installers are typically read-only)
    - Added BSD name pattern matching (disk images: `disk6`, real media: `disk2s1`)
    - Added diskutil verification to query if volume is a disk image
    - Expanded installer keyword list: "wacom", "driver", "pkg"
    - Added write-protect check via `kDADiskDescriptionMediaWritableKey`
  - **Now correctly ignores:** DSSPlayerV778, WacomTablet, all PKG/DMG installers
  - **Verified working:** No false positives with multiple disk images mounted

### Fixed - 2025-11-16
- **Fixed SD card detection to properly distinguish between disk images and real media** ✅ TESTED
  - Issue #1: DMG files (like "DSSPlayerV778" installer) were incorrectly detected as SD cards
  - Issue #2: Built-in SD card readers were rejected because macOS marks them as "internal"
  - Solution: Validate removable + local, but allow internal SD card readers
  - DiskArbitration callbacks check device protocol to exclude "Disk Image" and "Virtual Interface"
  - Added keyword filtering to skip installer/setup volumes ("installer", "dmg", "player", etc.)
  - Expanded system volume exclusion list (Preboot, Recovery, VM, Update, Data)
  - **Now correctly detects:** SD cards (internal/external readers) and USB drives
  - **Now correctly ignores:** DMG files, disk images, system volumes, installers
  - **Verified working:** Detects real SD cards while ignoring DSSPlayerV778 installer DMG

### Added - 2025-11-16
- **SD card eject functionality** ✅ TESTED
  - Added "Eject" button to SD card detection banner on main view
  - Added "Eject" button to SD Card Import sheet window
  - Uses `diskutil eject` command to safely unmount SD card
  - Button replaces progress indicator when not scanning files
  - **Verified working:** Successfully ejects SD cards from both locations

### Documentation Updates - 2025-11-16
- Created BACKLOG.md for project management and feature planning
- Added Technologies & Credits section to README documenting JOJO Transcribe tech stack
- Documented PM model usage guidelines (use Haiku for documentation tasks)
- Added Phase 6: UI/UX Design Review with NAV Design System alignment

---

## [0.2.0] - 2025-01-16

### Added - Phase 2: Recording Workflow
- Voice Memos integration - automatic launch on "Record with Voice Recorder" button
- Timestamped file naming: `lydfil_YYYYMMDD_HHMMSS.m4a`
- Automatic file storage to `~/Desktop/lydfiler` directory
- "Upload to Teams" button with automatic network enable/disable
- Manual network override controls (Enable/Disable Network buttons)
- Visual network status indicators for WiFi and Bluetooth state

### Changed
- Enhanced UI with large, researcher-friendly buttons
- Improved network control workflow for upload operations

---

## [0.1.0] - 2025-01-15

### Added - Phase 1: Core Security & UI
- Auto-launch on Mac startup capability (via LaunchAgent)
- Automatic network isolation on app launch (WiFi, Bluetooth, AirDrop disabled)
- macOS native app built with Swift 6.1+ and SwiftUI
- Basic UI framework with network control buttons
- Security-first architecture for zero-trust environments
- Integration with VG JOJO Transcribe app

### Security
- Network isolation as default state
- Administrator privileges required for network/Bluetooth control
- Designed for dedicated, single-purpose research computers

---

## Project Information

### Maintained By
Project Manager: Claude Code

### Documentation Standards
- **Format**: High-level summaries of features and changes
- **Updates**: After each feature implementation or significant change
- **Version**: Semantic versioning (MAJOR.MINOR.PATCH)

### Categories Used
- **Added**: New features
- **Changed**: Changes to existing functionality
- **Deprecated**: Soon-to-be removed features
- **Removed**: Removed features
- **Fixed**: Bug fixes
- **Security**: Security-related changes
