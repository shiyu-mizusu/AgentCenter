#!/bin/sh
# Builds a universal (Apple silicon + Intel) AgentCenter.app into ./build.
# Usage: scripts/build-app.sh [--zip]      VERSION=1.2.3 scripts/build-app.sh --zip
set -eu
cd "$(dirname "$0")/.."
VERSION="${VERSION:-0.1.0}"

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/AgentCenter"

APP=build/AgentCenter.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AgentCenter"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
sed "s/__VERSION__/$VERSION/g" Resources/Info.plist > "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"  # ad-hoc; swap in a Developer ID to notarize

if [ "${1:-}" = "--zip" ]; then
  ditto -c -k --keepParent "$APP" "build/AgentCenter-$VERSION.zip"
  echo "Built build/AgentCenter-$VERSION.zip"
fi
echo "Built $APP"
