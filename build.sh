#!/usr/bin/env bash
# Builds Jotter and installs it as ~/Applications/Jotter.app (or JOTTER_APP if set).
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
# The repo sits in iCloud-synced Documents; .nosync keeps build output out of iCloud.
SCRATCH=".build.nosync"

swift build -c "$CONFIG" --scratch-path "$SCRATCH"
BIN="$(swift build -c "$CONFIG" --scratch-path "$SCRATCH" --show-bin-path)/Jotter"

# Install outside iCloud, or sync metadata breaks the signature and macOS forgets permissions.
APP="${JOTTER_APP:-$HOME/Applications/Jotter.app}"
mkdir -p "$(dirname "$APP")"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Jotter"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/notes-schema.json "$APP/Contents/Resources/notes-schema.json"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
xattr -cr "$APP" 2>/dev/null || true

# A stable signing identity keeps microphone and audio permissions across rebuilds.
IDENTITY="${JOTTER_SIGN_IDENTITY:-IDEalize Local Signing}"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    codesign --force --deep --sign "$IDENTITY" "$APP"
else
    echo "No '$IDENTITY' certificate; signing ad hoc (permissions reset on each rebuild)."
    codesign --force --deep --sign - "$APP"
fi
codesign --verify --strict "$APP"
echo "Built $APP"
