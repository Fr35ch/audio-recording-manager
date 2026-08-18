# Clio — Distribution Runbook

This document describes how to build, sign, notarize and distribute the
Clio macOS app as a DMG with an embedded Python interpreter.

---

## Prerequisites

| Requirement | Notes |
|---|---|
| Xcode 15+ | With Command Line Tools installed |
| Apple Developer ID Application cert | Must be in your login keychain |
| Apple Developer account | With Team ID |
| notarytool keychain profile | See setup below |
| macOS 13+ build host | arm64 recommended (Apple Silicon) |
| Internet access during embed step | Downloads python-build-standalone |

### One-time notarytool credential setup

Run this **once** on the build machine and store the profile named
`clio-notary`. It is referenced by `sign-and-notarize.sh`.

```bash
xcrun notarytool store-credentials "clio-notary" \
  --apple-id  your@email.com \
  --team-id   XXXXXXXXXX \
  --password  xxxx-xxxx-xxxx-xxxx   # App-specific password from appleid.apple.com
```

---

## Build Sequence

### 1. Archive in Xcode

Either use Xcode's GUI (**Product → Archive**), or run from the command line:

```bash
xcodebuild \
  -project Clio.xcodeproj \
  -scheme Clio \
  -configuration Release \
  -archivePath build/Clio.xcarchive \
  archive
```

### 2. Export `.app`

```bash
xcodebuild \
  -exportArchive \
  -archivePath build/Clio.xcarchive \
  -exportPath build/export \
  -exportOptionsPlist packaging/ExportOptions.plist
```

> **Note**: You need a `packaging/ExportOptions.plist` — create one with
> `method = developer-id` and your Team ID. See [Apple docs][export-opts].

After this step you have `build/export/Clio.app`.

### 3. Embed Python

The Release target now runs `packaging/embed-python.sh` as a build phase,
so TestFlight/App Store archives contain the bundled interpreter
automatically. You can still run it manually on a built `.app` if needed:

```bash
bash packaging/embed-python.sh build/export/Clio.app
```

To **bump Python version** or the PBS release tag, edit the two variables
at the top of `packaging/embed-python.sh`:

```bash
PYTHON_VERSION="3.12"
PBS_RELEASE="20241016"
```

Available release tags and assets:
https://github.com/astral-sh/python-build-standalone/releases

### 4. Sign and notarize

```bash
# Export your cert name, team ID, and bundle ID (or hard-code them in the script)
export DEV_ID="Developer ID Application: Your Name (XXXXXXXXXX)"
export TEAM_ID="XXXXXXXXXX"
export BUNDLE_ID="com.yourcompany.clio"

bash packaging/sign-and-notarize.sh build/export/Clio.app
```

The script will:
1. Sign every Mach-O inside `Contents/Resources/python/` with `--options runtime`
2. Sign the `.app` with Hardened Runtime + `packaging/entitlements.plist`
3. Verify with `codesign --verify --deep --strict`
4. Create `build/export/Clio.dmg` (UDZO format)
5. Sign the DMG
6. Submit to Apple notarization (via `xcrun notarytool submit --wait`)
7. Staple the ticket (`xcrun stapler staple`)
8. Final Gatekeeper check (`spctl -a -vvv -t open`)

The final `Clio.dmg` is ready to distribute.

---

## First-run model downloads

The DMG contains only the Python interpreter and pip packages.
Model weights are **not** bundled — they are downloaded on first launch
by the `SetupFlowView` wizard (`Sources/Clio/SetupFlow.swift`):

| Component | Source | Size (approx.) |
|---|---|---|
| NB-Whisper Large | Hugging Face (`NbAiLab/nb-whisper-large`) | ~3 GB |
| spaCy `nb_core_news_lg` | spaCy model hub | ~600 MB |
| `qwen3:8b` (Ollama) | Ollama model registry | ~5 GB |

Models are cached in `~/Library/Application Support/Clio/models` (for
Hugging Face) and in Ollama's own storage for the Ollama model.

---

## Troubleshooting

### Common notarization rejections

**"Unsigned nested binary"**

Notarization scans the entire bundle. Any Mach-O that is missing a
signature will cause rejection. Find unsigned binaries:

```bash
codesign -vvv --deep "$APP" 2>&1 | grep "not signed"
# or
find "$APP" -type f | while read f; do
  file "$f" | grep -q "Mach-O" && codesign -v "$f" 2>&1 || true
done
```

Sign individually, then re-sign the app bundle.

---

**"Missing timestamp"**

All `codesign` invocations must include `--timestamp`. Without it,
notarization rejects the submission. Verify:

```bash
codesign -dvvv "$APP" 2>&1 | grep Timestamp
```

---

**"Missing hardened runtime"**

Every Mach-O in the bundle — including Python C-extension `.so` files —
must be signed with `--options runtime`. The `sign-and-notarize.sh`
script handles this automatically with the inner `find`/`file` loop.

---

**"Library validation failure"**

The hardened runtime's library-validation check rejects dylibs not signed
by Apple or by the same team as the app. Fix: ensure
`com.apple.security.cs.disable-library-validation` is set in
`packaging/entitlements.plist` and that the entitlements file is passed to
the top-level `codesign` invocation (`--entitlements`).

---

**"Invalid signature / main bundle"**

Caused by signing inner binaries AFTER the app bundle. The script signs
`Contents/Resources/python/**` first (inside-out), then the `.app`.
If you re-run codesign manually, always sign nested binaries before the
bundle.

---

**Torch `.so` files with no file extension**

`find … -name "*.so"` misses extension-less Mach-O objects that PyTorch
ships (e.g. `torch._C`). The script uses `file` detection, not filename
glob, so these are caught automatically. If you're writing custom signing
code, always use:

```bash
file "$f" | grep -q "Mach-O" && codesign ...
```

---

**"The package was not signed with a Developer ID certificate"**

Ensure you are using a **Developer ID Application** certificate, not a
Mac App Store or development certificate. Check with:

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```

---

[export-opts]: https://developer.apple.com/documentation/xcode/customizing-the-notarization-workflow
