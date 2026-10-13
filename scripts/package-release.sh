#!/bin/zsh
# Builds InterLude and zips it for a GitHub release, in dist/.
# ditto keeps the code signature intact; zipping in other ways can break it.
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build-app.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" build/InterLude.app/Contents/Info.plist)
mkdir -p dist
ZIP="dist/InterLude-$VERSION-macOS-arm64.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent build/InterLude.app "$ZIP"
# Check the copy people will download, not build/: iCloud can tag files in synced folders, which codesign rejects.
CHECK=$(mktemp -d)
ditto -x -k "$ZIP" "$CHECK"
codesign --verify --deep --strict "$CHECK/InterLude.app"
rm -rf "$CHECK"
echo "Packaged $ZIP (signature verified)"
shasum -a 256 "$ZIP"
