#!/bin/zsh
# Builds build/InterLude.app. Signs with the first Apple Development identity if there is one, else ad hoc.
# Set SANDBOX=0 to build without the App Sandbox.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
# Build outside Documents/iCloud: extended attributes there make codesign fail.
SB=${SCRATCH:-$HOME/Library/Caches/InterLudeBuild}
swift build -c release --scratch-path "$SB" --product InterLude
APP=build/InterLude.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$SB/release/InterLude" "$APP/Contents/MacOS/InterLude"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Data/stations.json "$APP/Contents/Resources/stations.json"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
ID=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')
ENT=Resources/InterLude.entitlements
if [[ "${SANDBOX:-1}" == "0" ]]; then
  ENT=$(mktemp); printf '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict/></plist>' > "$ENT"
fi
xattr -cr "$APP"
codesign --force --sign "${ID:--}" --entitlements "$ENT" --options runtime "$APP"
echo "Built $APP (signed with ${ID:-ad hoc identity}, sandbox=${SANDBOX:-1})"
