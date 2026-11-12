#!/usr/bin/env bash
# Installs or updates Jotter in ~/Applications.
#   curl -fsSL https://raw.githubusercontent.com/jamiejefferson/jotter/main/install.sh | bash
set -euo pipefail
REPO="jamiejefferson/jotter"
APP="$HOME/Applications/Jotter.app"

if [[ "$(uname -m)" != "arm64" ]]; then echo "Jotter needs a Mac with Apple silicon."; exit 1; fi
if (( $(sw_vers -productVersion | cut -d. -f1) < 26 )); then echo "Jotter needs macOS 26 or later."; exit 1; fi

# Never interrupt a recording: unfinished audio lives in .caf files until it is saved.
if pgrep -x Jotter >/dev/null && find "$HOME/Library/Application Support/Jotter/Recordings" -name '*.caf' 2>/dev/null | grep -q .; then
    echo "Jotter is recording. Stop the recording, then run this again."; exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
echo "Downloading Jotter…"
curl -fsSL "https://github.com/$REPO/releases/latest/download/Jotter.zip" -o "$TMP/Jotter.zip"
pkill -x Jotter 2>/dev/null || true
mkdir -p "$HOME/Applications"
rm -rf "$APP"
ditto -x -k "$TMP/Jotter.zip" "$HOME/Applications/"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
open "$APP"
echo "Jotter $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist") is installed. Look for its icon in the menu bar."
