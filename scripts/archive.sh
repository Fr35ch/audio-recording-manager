#!/bin/bash

# =============================================================================
# Clio - Archive Script
# =============================================================================
# Builds a distributable .xcarchive for TestFlight/App Store submission.
#
# Why not just use Xcode's Product > Archive menu?
# --------------------------------------------------
# FluidAudio (an SPM dependency, used for on-device speaker diarization) has
# a handful of files with unguarded `Float16` usage, which is an arm64-only
# Swift built-in. Xcode's Archive action builds a universal binary (arm64 +
# x86_64) by default, and while Clio's own project build settings are
# restricted to arm64, that restriction does NOT propagate to Swift Package
# dependencies -- Xcode resolves each package's architectures independently.
# The only setting that reliably propagates into package sub-targets is a
# build-setting override on the xcodebuild invocation itself, which is what
# this script provides. See docs/decisions/adr/ for the full writeup if one
# exists, or the git history of this file for context.
#
# Usage:
#   ./scripts/archive.sh                  # archive to build/Clio.xcarchive
#   ./scripts/archive.sh /path/to/out.xcarchive
#
# After archiving, open the .xcarchive (double-click, or `open <path>`) to
# load it into Xcode's Organizer for TestFlight/App Store upload, exactly as
# if it had been archived from Xcode's own Product > Archive menu.
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ARCHIVE_PATH="${1:-$PROJECT_ROOT/build/Clio.xcarchive}"

mkdir -p "$(dirname "$ARCHIVE_PATH")"

echo "Archiving Clio to: $ARCHIVE_PATH"

xcodebuild \
  -project "$PROJECT_ROOT/Clio.xcodeproj" \
  -scheme Clio \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  -destination "generic/platform=macOS" \
  ARCHS=arm64 \
  EXCLUDED_ARCHS=x86_64 \
  ONLY_ACTIVE_ARCH=NO \
  archive

echo ""
echo "Archive succeeded: $ARCHIVE_PATH"
echo "Open it in Xcode Organizer with:"
echo "  open \"$ARCHIVE_PATH\""
