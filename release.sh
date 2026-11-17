#!/usr/bin/env bash
# Builds Jotter, zips it and publishes it as a GitHub release, which install.sh downloads.
# Usage: ./release.sh [--no-publish]   (version comes from Resources/Info.plist)
set -euo pipefail
cd "$(dirname "$0")"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
# Assemble outside iCloud-synced Documents: sync metadata on the files breaks the signature.
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
JOTTER_APP="$OUT/Jotter.app" ./build.sh
ditto -c -k --keepParent "$OUT/Jotter.app" "$OUT/Jotter.zip"
mkdir -p dist.nosync && cp "$OUT/Jotter.zip" dist.nosync/Jotter.zip
echo "Built dist.nosync/Jotter.zip for $VERSION"
if [[ "${1:-}" != "--no-publish" ]]; then
    gh release create "v$VERSION" dist.nosync/Jotter.zip install.sh --repo jamiejefferson/jotter --title "Jotter $VERSION" --notes "${NOTES:-Jotter $VERSION}" --latest
fi
