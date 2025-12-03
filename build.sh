#!/bin/bash

# Build script for Audio Recording Manager (ARM) macOS app
# This script compiles the Swift app and creates a proper .app bundle

set -e  # Exit on error

APP_NAME="AudioRecordingManager"
BUNDLE_ID="com.audiorecordingmanager.app"
BUILD_DIR="build"

# Read version from VERSION file
VERSION_FILE="VERSION"
if [ -f "$VERSION_FILE" ]; then
    APP_VERSION=$(cat "$VERSION_FILE" | tr -d '\n')
else
    APP_VERSION="1.0.0"
fi
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "🔨 Building Audio Recording Manager v$APP_VERSION..."

# Clean previous build
if [ -d "$BUILD_DIR" ]; then
    echo "🧹 Cleaning previous build..."
    rm -rf "$BUILD_DIR"
fi

# Create app bundle structure
echo "📁 Creating app bundle structure..."
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

# Compile Swift source
echo "⚙️  Compiling Swift source..."

# First try with Xcode SDK (required for proper Sequoia styling)
XCODE_SDK="/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"

if [ -d "$XCODE_SDK" ]; then
    echo "   Using Xcode SDK for proper Sequoia window styling..."
    /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc \
        -o "$MACOS_DIR/$APP_NAME" \
        Sources/AudioRecordingManager/main.swift \
        Sources/AudioRecordingManager/SVGImageView.swift \
        -parse-as-library \
        -target arm64-apple-macos15.0 \
        -framework SwiftUI \
        -framework AppKit \
        -framework WebKit \
        -framework CoreWLAN \
        -framework IOBluetooth \
        -framework DiskArbitration \
        -sdk "$XCODE_SDK"
else
    echo "   ⚠️  Xcode SDK not found - using Command Line Tools (may have incorrect window styling)"
    swiftc \
        -o "$MACOS_DIR/$APP_NAME" \
        Sources/AudioRecordingManager/main.swift \
        Sources/AudioRecordingManager/SVGImageView.swift \
        -parse-as-library \
        -target arm64-apple-macos15.0 \
        -framework SwiftUI \
        -framework AppKit \
        -framework WebKit \
        -framework CoreWLAN \
        -framework IOBluetooth \
        -framework DiskArbitration
fi

# Copy Info.plist
echo "📋 Copying Info.plist..."
cp Info.plist "$CONTENTS_DIR/Info.plist"

# Copy Assets to Resources
echo "📦 Copying assets to Resources..."
if [ -d "Assets" ]; then
    cp -r Assets/* "$RESOURCES_DIR/"
    echo "   ✓ Assets copied"
fi

# Copy Resources (including aksel-icons)
if [ -d "Resources" ]; then
    cp -r Resources/* "$RESOURCES_DIR/"
    echo "   ✓ Resources copied"
fi

# Create PkgInfo file
echo "📄 Creating PkgInfo..."
echo -n "APPL????" > "$CONTENTS_DIR/PkgInfo"

# Make executable
chmod +x "$MACOS_DIR/$APP_NAME"

echo "✅ Build complete!"
echo "📦 App bundle created at: $APP_BUNDLE"
echo ""
echo "To run the app:"
echo "  open $APP_BUNDLE"
echo ""
echo "⚠️  Note: The app requires administrator privileges to control network/Bluetooth."
echo "   You may need to grant permissions in System Settings > Privacy & Security"
