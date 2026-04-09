#!/bin/bash
set -e

APP_NAME="slyTerm"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

echo "Building $APP_NAME..."

# Clean
rm -rf "$BUILD_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Compile
swiftc -O -o "$APP_BUNDLE/Contents/MacOS/$APP_NAME" \
    slyTerm.swift \
    -framework Cocoa -framework WebKit \
    -target arm64-apple-macos14.0

# Copy resources
cp AppIcon.icns "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

# Info.plist
cat > "$APP_BUNDLE/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>slyTerm</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.sly.slyterm</string>
    <key>CFBundleName</key>
    <string>slyTerm</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# Sign
codesign --force --deep --sign - "$APP_BUNDLE"

echo "Built: $APP_BUNDLE"
