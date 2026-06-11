#!/usr/bin/env bash
# packaging/sign-and-notarize.sh
#
# Signs all nested Mach-O binaries inside the app bundle (inside-out),
# signs the .app itself with Hardened Runtime + entitlements, creates
# a UDZO DMG, notarizes it with Apple's notarytool, and staples the
# notarization ticket.
#
# Usage:
#   bash packaging/sign-and-notarize.sh <path/to/Clio.app>
#
# Prerequisites:
#   • A valid "Developer ID Application" certificate in your login keychain.
#   • A notarytool keychain profile created with:
#       xcrun notarytool store-credentials "clio-notary" \
#         --apple-id <your@email.com> \
#         --team-id <TEAM_ID> \
#         --password <app-specific-password>
#   • Xcode Command Line Tools (codesign, hdiutil, xcrun).
#
# References:
#   https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration — fill in your own values or export from the environment.
# ---------------------------------------------------------------------------
DEV_ID="${DEV_ID:-Developer ID Application: Your Name (TEAMID)}"
TEAM_ID="${TEAM_ID:-XXXXXXXXXX}"
BUNDLE_ID="${BUNDLE_ID:-com.yourcompany.clio}"
ENTITLEMENTS_PLIST="$(dirname "$0")/entitlements.plist"

# ---------------------------------------------------------------------------
# Resolve .app path
# ---------------------------------------------------------------------------
if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <path/to/Clio.app>" >&2
    exit 1
fi
APP="$1"

if [[ ! -d "$APP" ]]; then
    echo "❌ .app bundle not found: $APP" >&2
    exit 1
fi

# DMG will be placed next to the .app
DMG_DIR="$(dirname "$APP")"
DMG_PATH="${DMG_DIR}/Clio.dmg"

echo "✅ Signing bundle: $APP"
echo "   Developer ID: $DEV_ID"
echo "   Entitlements: $ENTITLEMENTS_PLIST"
echo ""

# ---------------------------------------------------------------------------
# Step 1: Sign all nested Mach-O binaries inside-out.
#
# We must sign nested binaries BEFORE the top-level .app bundle,
# otherwise the bundle signature over Contents/ becomes invalid when
# codesign rewrites an inner binary.
#
# We use `file` to detect Mach-O so that extension-less Mach-O files
# (common in PyTorch .so objects) are caught, not just *.dylib/*.so.
# ---------------------------------------------------------------------------
echo "🔐 Step 1: Signing nested Mach-O binaries in $APP/Contents/Resources/python …"
find "$APP/Contents/Resources/python" -type f | while read -r f; do
    if file "$f" | grep -q "Mach-O"; then
        echo "   signing: $f"
        codesign \
            --force \
            --options runtime \
            --timestamp \
            --sign "$DEV_ID" \
            "$f"
    fi
done
echo "   ✅ Nested binaries signed."

# ---------------------------------------------------------------------------
# Step 2: Sign the .app bundle with Hardened Runtime + entitlements.
# ---------------------------------------------------------------------------
echo ""
echo "🔐 Step 2: Signing .app bundle …"
codesign \
    --force \
    --deep \
    --options runtime \
    --timestamp \
    --entitlements "$ENTITLEMENTS_PLIST" \
    --sign "$DEV_ID" \
    "$APP"
echo "   ✅ App bundle signed."

# ---------------------------------------------------------------------------
# Step 3: Verify signature integrity.
# ---------------------------------------------------------------------------
echo ""
echo "🔍 Step 3: Verifying code signature …"
if ! codesign --verify --deep --strict --verbose=2 "$APP"; then
    echo "❌ Signature verification failed. Aborting." >&2
    exit 1
fi
echo "   ✅ Signature verified."

# ---------------------------------------------------------------------------
# Step 4: Build UDZO DMG.
# ---------------------------------------------------------------------------
echo ""
echo "💿 Step 4: Creating DMG at $DMG_PATH …"
rm -f "$DMG_PATH"
hdiutil create \
    -volname "Clio" \
    -srcfolder "$APP" \
    -ov \
    -format UDZO \
    "$DMG_PATH"
echo "   ✅ DMG created."

# ---------------------------------------------------------------------------
# Step 5: Sign the DMG.
# ---------------------------------------------------------------------------
echo ""
echo "🔐 Step 5: Signing DMG …"
codesign \
    --force \
    --timestamp \
    --sign "$DEV_ID" \
    "$DMG_PATH"
echo "   ✅ DMG signed."

# ---------------------------------------------------------------------------
# Step 6: Submit to Apple notarization service.
# ---------------------------------------------------------------------------
echo ""
echo "📤 Step 6: Submitting to Apple notarytool (this may take several minutes) …"
xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "clio-notary" \
    --wait
echo "   ✅ Notarization accepted."

# ---------------------------------------------------------------------------
# Step 7: Staple the notarization ticket to the DMG.
# ---------------------------------------------------------------------------
echo ""
echo "📎 Step 7: Stapling notarization ticket …"
xcrun stapler staple "$DMG_PATH"
echo "   ✅ Ticket stapled."

# ---------------------------------------------------------------------------
# Step 8: Final Gatekeeper verification.
# ---------------------------------------------------------------------------
echo ""
echo "🔍 Step 8: Verifying with spctl (Gatekeeper) …"
spctl -a -vvv -t open --context context:primary-signature "$DMG_PATH"
echo "   ✅ Gatekeeper check passed."

echo ""
echo "🎉 Done! Distributable DMG: $DMG_PATH"
