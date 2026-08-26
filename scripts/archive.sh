#!/bin/bash

# =============================================================================
# Clio - Archive Script
# =============================================================================
# Builds a distributable .xcarchive for TestFlight/App Store submission.
#
# You can now also use Xcode's Product > Archive menu directly -- see below
# for the history of why this script exists and what changed.
#
# History: why this script was originally required
# --------------------------------------------------
# FluidAudio (an SPM dependency, used for on-device speaker diarization) added
# new ASR/TTS modules (ParaformerManager, LogitsArgmax, NeuTtsSynthesizer --
# none of which Clio uses, but which still have to compile as part of the
# package) with unguarded `Float16` usage, an arm64-only Swift built-in,
# starting in FluidAudio 0.15.x. Xcode's Archive action builds a universal
# binary (arm64 + x86_64) by default, and while Clio's own project build
# settings are restricted to arm64, that restriction does NOT propagate to
# Swift Package dependencies -- Xcode resolves each package's architectures
# independently. This script's ARCHS=arm64/EXCLUDED_ARCHS=x86_64 command-line
# override was the only thing that reliably reached FluidAudio's package
# sub-targets, so archiving via Xcode's own menu failed every time.
#
# Fixed at the source instead: Clio.xcodeproj's FluidAudio package reference
# is now pinned to an exact version (0.14.5) that predates those modules --
# confirmed via the FluidAudio GitHub repo that ParaformerManager/
# LogitsArgmax/NeuTtsSynthesizer don't exist at that tag, and verified with a
# real plain `xcodebuild archive` (no overrides) that it now succeeds. Xcode's
# Product > Archive menu should work normally again. This script is kept as a
# defensive fallback (e.g. for CI, or in case the pin is ever bumped again
# without re-checking for this issue) -- the ARCHS override here is harmless
# even when not strictly required.
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
