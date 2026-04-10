#!/bin/zsh
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$SRC_DIR/build/slyTerm.app"
BIN_DIR="$APP/Contents/MacOS"
RES_DIR="$APP/Contents/Resources"

rm -rf "$APP"
mkdir -p "$BIN_DIR" "$RES_DIR"

# Compile
xcrun swiftc \
  -O \
  -target arm64-apple-macos14.0 \
  -framework Cocoa \
  -framework WebKit \
  "$SRC_DIR/main.swift" \
  -o "$BIN_DIR/slyTerm"

# Info.plist
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>slyTerm</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>com.sly.slyterm</string>
    <key>CFBundleName</key><string>slyTerm</string>
    <key>CFBundleDisplayName</key><string>slyTerm</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>2.1</string>
    <key>CFBundleVersion</key><string>3</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key><true/>
        <key>NSExceptionDomains</key>
        <dict>
            <key>localhost</key>
            <dict>
                <key>NSExceptionAllowsInsecureHTTPLoads</key><true/>
                <key>NSIncludesSubdomains</key><true/>
            </dict>
        </dict>
    </dict>
</dict>
</plist>
PLIST

# Copy icon from existing install if present
if [ -f "/Applications/slyTerm.app/Contents/Resources/AppIcon.icns" ]; then
  cp "/Applications/slyTerm.app/Contents/Resources/AppIcon.icns" "$RES_DIR/AppIcon.icns"
fi

# DockAnimator active-frame: pixelated DJ creature shown while typing
if [ -f "$SRC_DIR/claude_dj.png" ]; then
  cp "$SRC_DIR/claude_dj.png" "$RES_DIR/claude_dj.png"
fi

# Ad-hoc sign so Gatekeeper lets it run
codesign --force --sign - "$APP"

echo "Built: $APP"
