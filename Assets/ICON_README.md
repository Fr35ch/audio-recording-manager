# Virgin Project App Icon

## Overview
The Virgin Project macOS app now has a professional app icon created from the iOS icon assets.

## Icon Files

### Source Icon
- **Location**: `iOS_AppIcon_Assets/Icon-App-1024x1024@1x.png`
- **Size**: 1024x1024 pixels
- **Format**: PNG

### macOS Icon Files Created

1. **VirginProject.icns** (Main macOS icon)
   - Location: `Assets/VirginProject.icns`
   - Size: 1.8 MB
   - Contains all required sizes for macOS (16x16 to 1024x1024 @1x and @2x)

2. **VirginProject.iconset/** (Icon source files)
   - Location: `Assets/VirginProject.iconset/`
   - Contains individual PNG files for each size:
     - icon_16x16.png / icon_16x16@2x.png
     - icon_32x32.png / icon_32x32@2x.png
     - icon_128x128.png / icon_128x128@2x.png
     - icon_256x256.png / icon_256x256@2x.png
     - icon_512x512.png / icon_512x512@2x.png

## Integration

### Info.plist
Added the following key to reference the icon:
```xml
<key>CFBundleIconFile</key>
<string>VirginProject</string>
```

### Build Process
The `build.sh` script automatically:
1. Copies all Assets (including VirginProject.icns) to the app bundle's Resources folder
2. The icon appears in:
   - Dock when app is running
   - Finder when viewing the .app bundle
   - Mission Control and window switcher
   - Spotlight search results

## Icon Sizes Included

| Size | Retina | Use Case |
|------|--------|----------|
| 16x16 | ✓ | Menu bar, small lists |
| 32x32 | ✓ | Standard lists, Dock (small) |
| 128x128 | ✓ | Medium Dock, Get Info window |
| 256x256 | ✓ | Large Dock, Finder icons |
| 512x512 | ✓ | Retina Dock, large previews |
| 1024x1024 | - | App Store, high-res displays |

## Rebuilding the Icon

If you need to regenerate the icon from a new source image:

```bash
cd /Users/Fredrik.Scheide/Github/virgin-project/Assets

# 1. Update the source image
# Replace iOS_AppIcon_Assets/Icon-App-1024x1024@1x.png with new 1024x1024 image

# 2. Regenerate iconset
SOURCE_ICON="iOS_AppIcon_Assets/Icon-App-1024x1024@1x.png"
ICONSET_DIR="VirginProject.iconset"

rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"

sips -z 16 16     "$SOURCE_ICON" --out "$ICONSET_DIR/icon_16x16.png"
sips -z 32 32     "$SOURCE_ICON" --out "$ICONSET_DIR/icon_16x16@2x.png"
sips -z 32 32     "$SOURCE_ICON" --out "$ICONSET_DIR/icon_32x32.png"
sips -z 64 64     "$SOURCE_ICON" --out "$ICONSET_DIR/icon_32x32@2x.png"
sips -z 128 128   "$SOURCE_ICON" --out "$ICONSET_DIR/icon_128x128.png"
sips -z 256 256   "$SOURCE_ICON" --out "$ICONSET_DIR/icon_128x128@2x.png"
sips -z 256 256   "$SOURCE_ICON" --out "$ICONSET_DIR/icon_256x256.png"
sips -z 512 512   "$SOURCE_ICON" --out "$ICONSET_DIR/icon_256x256@2x.png"
sips -z 512 512   "$SOURCE_ICON" --out "$ICONSET_DIR/icon_512x512.png"
sips -z 1024 1024 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_512x512@2x.png"

# 3. Create .icns file
iconutil -c icns VirginProject.iconset -o VirginProject.icns

# 4. Rebuild the app
cd ..
./build.sh
```

## Verification

To verify the icon is properly installed:

```bash
# Check icon is in app bundle
ls -lh build/VirginProject.app/Contents/Resources/VirginProject.icns

# View icon in Finder
open -R build/VirginProject.app

# Check icon metadata
mdls -name kMDItemDisplayName -name kMDItemContentType build/VirginProject.app
```

## Notes

- The icon cache may take a moment to update after building
- If the icon doesn't appear immediately, try:
  - Restarting the Dock: `killall Dock`
  - Clearing icon cache: `sudo rm -rf /Library/Caches/com.apple.iconservices.store`
  - Rebuilding the app: `./build.sh`

---

**Created**: 2025-11-15
**Last Updated**: 2025-11-15
