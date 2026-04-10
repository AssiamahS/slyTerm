#!/bin/bash
set -e

echo "==================================="
echo "  slyTerm Installer"
echo "==================================="
echo ""

# Check macOS version
if [[ "$(uname)" != "Darwin" ]]; then
    echo "Error: slyTerm only runs on macOS."
    exit 1
fi

# Check for ttyd
if ! command -v ttyd &>/dev/null; then
    echo "ttyd is required but not installed."
    echo ""
    if command -v brew &>/dev/null; then
        read -p "Install ttyd via Homebrew? [Y/n] " yn
        case ${yn:-Y} in
            [Yy]*) brew install ttyd ;;
            *) echo "Please install ttyd manually: brew install ttyd"; exit 1 ;;
        esac
    else
        echo "Install Homebrew first: https://brew.sh"
        echo "Then run: brew install ttyd"
        exit 1
    fi
fi

# Build
echo "Building slyTerm..."
./build.sh

# Install
echo "Installing to /Applications..."
rm -rf /Applications/slyTerm.app
cp -R build/slyTerm.app /Applications/

# Remove quarantine
xattr -r -d com.apple.quarantine /Applications/slyTerm.app 2>/dev/null || true

# Setup ttyd LaunchAgent
PLIST_PATH="$HOME/Library/LaunchAgents/com.sly.ttyd.plist"
TTYD_PATH="$(which ttyd)"

if [ ! -f "$PLIST_PATH" ]; then
    read -p "Start ttyd automatically on login? [Y/n] " yn
    case ${yn:-Y} in
        [Yy]*)
            mkdir -p "$HOME/Library/LaunchAgents"
            cat > "$PLIST_PATH" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.sly.ttyd</string>
    <key>ProgramArguments</key>
    <array>
        <string>$TTYD_PATH</string>
        <string>-W</string>
        <string>-p</string>
        <string>7681</string>
        <string>-i</string>
        <string>127.0.0.1</string>
        <string>/bin/zsh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
EOF
            launchctl load "$PLIST_PATH" 2>/dev/null || true
            echo "ttyd LaunchAgent installed."
            ;;
    esac
fi

# Ensure ttyd is running now
if ! pgrep -q ttyd; then
    echo "Starting ttyd..."
    "$TTYD_PATH" -W -p 7681 -i 127.0.0.1 /bin/zsh &
    sleep 1
fi

echo ""
echo "==================================="
echo "  slyTerm installed successfully!"
echo "==================================="
echo ""
echo "  Open from: /Applications/slyTerm.app"
echo "  Or run:    open -a slyTerm"
echo ""
echo "  Shortcuts:"
echo "    Cmd+N  New window"
echo "    Cmd+T  New split pane (up to 4)"
echo "    Cmd+W  Close split / window"
echo "    Cmd+Q  Quit"
echo ""
