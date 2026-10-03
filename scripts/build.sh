#!/bin/bash
# Builds OpenTranscribe.app into .build/, signed with a stable local identity so the microphone
# and system-audio permissions survive a rebuild.
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-release}"
APP=".build/OpenTranscribe.app"

swift build -c "$CONFIG" --product opentranscribed
swift build -c "$CONFIG" --product otcli

BIN=".build/$CONFIG"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/opentranscribed" "$APP/Contents/MacOS/OpenTranscribe"
cp "$BIN/otcli" "$APP/Contents/MacOS/otcli"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# A stable identity keeps the microphone and system-audio permissions across rebuilds.
IDENTITY="$(./scripts/ensure-signing-identity.sh)"
# No entitlements file on purpose: the app is not sandboxed, the sandbox audio-input
# entitlement is inert here, and signing with it is the one difference against a local app that
# records fine on this machine.
codesign --force --deep --sign "$IDENTITY" "$APP" >/dev/null

echo "built $APP"
