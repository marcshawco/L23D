#!/bin/bash
# Builds L23D HQ (Release) and installs it as /Applications/L23D HQ.app.
# Run again after pulling new code. Blender comes from: brew install --cask blender
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild -project L23D.xcodeproj -scheme "L23D HQ" -configuration Release -derivedDataPath build/dd build -quiet
rm -rf "/Applications/L23D HQ.app"
ditto build/dd/Build/Products/Release/L23DHQ.app "/Applications/L23D HQ.app"
echo "Installed /Applications/L23D HQ.app"
