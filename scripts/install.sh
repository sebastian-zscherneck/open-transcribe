#!/bin/bash
# Builds, installs into /Applications and restarts the daemon.
set -euo pipefail

cd "$(dirname "$0")/.."
./scripts/build.sh

osascript -e 'quit app "OpenTranscribe"' 2>/dev/null || true
sleep 1

rm -rf /Applications/OpenTranscribe.app
cp -R .build/OpenTranscribe.app /Applications/OpenTranscribe.app

# Handy for the debug CLI without typing the bundle path.
mkdir -p "$HOME/.local/bin"
ln -sf /Applications/OpenTranscribe.app/Contents/MacOS/otcli "$HOME/.local/bin/otcli"

open /Applications/OpenTranscribe.app
echo "installed and started. try: otcli status"
