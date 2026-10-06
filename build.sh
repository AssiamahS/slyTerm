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
  -import-objc-header "$SRC_DIR/bridge.h" \
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
    <key>CFBundleShortVersionString</key><string>2.9.0</string>
    <key>CFBundleVersion</key><string>13</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>slyTerm forks the tmux server that runs your Claude Code chats; the microphone grant lets voice input in every tab hear you.</string>
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

# Icon ships from the repo. It used to be copied out of the installed app, so
# once that copy was lost (9/28 reinstall from Trash) every build after it went
# out with the generic placeholder icon.
cp "$SRC_DIR/AppIcon.icns" "$RES_DIR/AppIcon.icns"

# DockAnimator active-frame: pixelated DJ creature shown while typing
if [ -f "$SRC_DIR/claude_dj.png" ]; then
  cp "$SRC_DIR/claude_dj.png" "$RES_DIR/claude_dj.png"
fi

# Ad-hoc sign. Do NOT sign with the Apple Development identity in the keychain:
# cert 9Q38C6TT37 is REVOKED, and macOS 26 treats a revoked signature as malware
# ("slyTerm.app was not opened because it contains malware") — launchd refuses
# to spawn it (error 163) and Finder moves it to the Trash (2026-09-28).
# spctl reports CSSMERR_TP_CERT_REVOKED only after an async OCSP check, so a
# post-sign assessment cannot be trusted as a guard either. A stable identity
# for the TCC mic grant has to be a NEW, valid cert (self-signed or re-issued).
#
# 2026-10-06: ad hoc = new cdhash every build, so TCC forgot the Documents
# grant after each rebuild and every new tab re-prompted (pane processes are
# attributed to slyTerm since it owns the tmux server). Sign with the local
# self-signed "slyTerm Local Signing" cert instead: the designated requirement
# pins the leaf hash, which never changes, so grants survive rebuilds.
# Self-signed is never "revoked", so the malware trap above can't fire.
SIGN_ID="${SLYTERM_SIGN_ID:-slyTerm Local Signing}"
if security find-identity -p codesigning | grep -q "\"$SIGN_ID\""; then
  codesign --force --sign "$SIGN_ID" "$APP"
  echo "Signed with $SIGN_ID"
else
  codesign --force --sign - "$APP"
  echo "Signed ad hoc (no '$SIGN_ID' identity in keychain; TCC grants reset per build)"
fi

echo "Built: $APP"

# Install to /Applications (no Finder copy needed — djsly is in admin group)
INSTALL_DST="/Applications/slyTerm.app"
if pgrep -x slyTerm >/dev/null; then
  # No osascript: AppleEvents to slyTerm hang when this runs from a chat tab.
  # Chats live in tmux, so killing the app loses nothing; relaunch re-adopts.
  echo "Quitting running slyTerm..."
  pkill -x slyTerm 2>/dev/null || true
  sleep 1
fi
rm -rf "$INSTALL_DST"
cp -R "$APP" "$INSTALL_DST"
xattr -dr com.apple.quarantine "$INSTALL_DST" 2>/dev/null || true
echo "Installed: $INSTALL_DST"
