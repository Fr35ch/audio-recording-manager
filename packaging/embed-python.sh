#!/usr/bin/env bash
# packaging/embed-python.sh
#
# Downloads a python-build-standalone (PBS) interpreter for Apple Silicon,
# installs no-transcribe and no-anonymizer into the app bundle, and verifies
# that the imports work offline.
#
# Usage:
#   bash packaging/embed-python.sh <path/to/Clio.app>
#
# Example:
#   bash packaging/embed-python.sh build/export/Clio.app
#
# The script expects $1 to be the path to the .app bundle. If omitted it
# falls back to a typical DerivedData location for local development.
#
# PBS release tags: https://github.com/astral-sh/python-build-standalone/releases
# Choose an "install_only" aarch64 tarball. Update PBS_RELEASE to bump Python.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration — edit here to bump Python or the PBS release date tag.
# ---------------------------------------------------------------------------
PYTHON_VERSION="3.12"
# PBS release date tag — see https://github.com/astral-sh/python-build-standalone/releases
PBS_RELEASE="20241016"

# Developer ID Application certificate name (CN in Keychain)
DEV_ID="${DEV_ID:-Developer ID Application: Your Name (TEAMID)}"
TEAM_ID="${TEAM_ID:-XXXXXXXXXX}"
BUNDLE_ID="${BUNDLE_ID:-com.yourcompany.clio}"

# ---------------------------------------------------------------------------
# Resolve .app path
# ---------------------------------------------------------------------------
DEFAULT_APP="$HOME/Library/Developer/Xcode/DerivedData/Clio-*/Build/Products/Release/Clio.app"

if [[ $# -ge 1 ]]; then
    APP="$1"
else
    # Glob expansion for DerivedData default
    APP=$(echo $DEFAULT_APP | head -n1)
    if [[ -z "$APP" || ! -d "$APP" ]]; then
        echo "Usage: $0 <path/to/Clio.app>" >&2
        echo "  Could not find Clio.app in DerivedData. Pass the path explicitly." >&2
        exit 1
    fi
    echo "ℹ️  No .app path given — using DerivedData: $APP"
fi

if [[ ! -d "$APP" ]]; then
    echo "❌ .app bundle not found: $APP" >&2
    exit 1
fi

echo "✅ Target bundle: $APP"

# ---------------------------------------------------------------------------
# Resolve destination inside bundle
# ---------------------------------------------------------------------------
PYTHON_DIR="$APP/Contents/Resources/python"

# ---------------------------------------------------------------------------
# Download PBS tarball
# ---------------------------------------------------------------------------
PBS_FILENAME="cpython-${PYTHON_VERSION}.*-aarch64-apple-darwin-install_only.tar.gz"
PBS_BASE_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_RELEASE}"

echo ""
echo "⬇️  Resolving PBS tarball for Python ${PYTHON_VERSION} (${PBS_RELEASE}) …"

# Use GitHub API to find the correct asset name for this release
ASSET_NAME=$(curl -fsSL \
    "https://api.github.com/repos/astral-sh/python-build-standalone/releases/tags/${PBS_RELEASE}" \
    | python3 -c "
import sys, json
data = json.load(sys.stdin)
assets = [a['name'] for a in data.get('assets', [])
          if 'aarch64-apple-darwin' in a['name']
          and 'install_only' in a['name']
          and a['name'].startswith('cpython-${PYTHON_VERSION}')]
if not assets:
    print('ERROR: no matching asset', file=sys.stderr)
    sys.exit(1)
print(sorted(assets)[0])
")

echo "   Asset: $ASSET_NAME"
TARBALL_URL="${PBS_BASE_URL}/${ASSET_NAME}"
TARBALL_PATH="/tmp/${ASSET_NAME}"

if [[ -f "$TARBALL_PATH" ]]; then
    echo "   (cached at $TARBALL_PATH)"
else
    echo "   Downloading from $TARBALL_URL …"
    curl -fL --progress-bar -o "$TARBALL_PATH" "$TARBALL_URL"
fi

# ---------------------------------------------------------------------------
# Extract into bundle Resources
# ---------------------------------------------------------------------------
echo ""
echo "📦 Extracting to $PYTHON_DIR …"
rm -rf "$PYTHON_DIR"
mkdir -p "$APP/Contents/Resources"

# PBS tarballs unpack to a "python/" directory
tar -xzf "$TARBALL_PATH" -C "$APP/Contents/Resources/"

# Sanity check
if [[ ! -x "$PYTHON_DIR/bin/python3" ]]; then
    echo "❌ Expected interpreter not found at $PYTHON_DIR/bin/python3" >&2
    exit 1
fi

echo "   Interpreter: $("$PYTHON_DIR/bin/python3" --version)"

# ---------------------------------------------------------------------------
# Install Python packages into the bundled interpreter (not a venv)
# ---------------------------------------------------------------------------
echo ""
echo "📥 Upgrading pip …"
"$PYTHON_DIR/bin/python3" -m pip install --upgrade pip

echo ""
echo "📥 Installing no-transcribe and no-anonymizer …"
"$PYTHON_DIR/bin/python3" -m pip install no-transcribe no-anonymizer

# ---------------------------------------------------------------------------
# Offline import verification (must not trigger model downloads)
# ---------------------------------------------------------------------------
echo ""
echo "🔍 Verifying imports (offline, no model downloads) …"
HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 \
    "$PYTHON_DIR/bin/python3" -c "import no_transcribe, no_anonymizer; print('OK')"
echo "   ✅ Imports OK"

# ---------------------------------------------------------------------------
# Strip __pycache__ and RECORD files (reduce bundle size)
# Do NOT remove .so or .dylib files — they are required at runtime.
# ---------------------------------------------------------------------------
echo ""
echo "🧹 Stripping __pycache__ and *.dist-info/RECORD …"
find "$PYTHON_DIR" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
find "$PYTHON_DIR" -type f -name "RECORD" -path "*.dist-info/*" -delete 2>/dev/null || true

# ---------------------------------------------------------------------------
# Report bundle size
# ---------------------------------------------------------------------------
echo ""
BUNDLE_SIZE=$(du -sh "$PYTHON_DIR" | cut -f1)
echo "📊 Bundled Python size: $BUNDLE_SIZE"
echo ""
echo "✅ embed-python.sh complete."
