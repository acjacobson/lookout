#!/bin/sh
# Builds build/Lookout.app from the Swift package and signs it ad hoc.
set -eu
cd "$(dirname "$0")/.."

swift build -c release

app=build/Lookout.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/Lookout "$app/Contents/MacOS/Lookout"
cp Support/Info.plist "$app/Contents/Info.plist"
cp scripts/lookout-report "$app/Contents/Resources/lookout-report"
cp scripts/lookout-hooks.py "$app/Contents/Resources/lookout-hooks.py"
codesign --force --sign - "$app"

echo "Built $app"
