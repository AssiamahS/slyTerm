#!/bin/bash
set -e

APP_NAME="slyTerm"
DMG_NAME="slyTerm-Installer"
BUILD_DIR="build"
DMG_DIR="$BUILD_DIR/dmg"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

# Build first if needed
if [ ! -d "$APP_BUNDLE" ]; then
    echo "App not found, building first..."
    ./build.sh
fi

echo "Creating DMG installer..."

# Prepare DMG staging
rm -rf "$DMG_DIR"
mkdir -p "$DMG_DIR"
cp -R "$APP_BUNDLE" "$DMG_DIR/"

# Create symlink to Applications
ln -s /Applications "$DMG_DIR/Applications"

# Create DMG
rm -f "$BUILD_DIR/$DMG_NAME.dmg"
hdiutil create -volname "$APP_NAME" \
    -srcfolder "$DMG_DIR" \
    -ov -format UDZO \
    "$BUILD_DIR/$DMG_NAME.dmg"

# Cleanup staging
rm -rf "$DMG_DIR"

echo ""
echo "Installer created: $BUILD_DIR/$DMG_NAME.dmg"
echo "Users drag slyTerm.app to Applications to install."
