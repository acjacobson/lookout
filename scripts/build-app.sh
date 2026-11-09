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
# Sign with an Apple Development certificate when one exists. macOS refuses
# notifications from ad hoc signed apps ("Notifications are not allowed for this
# application"). Set LOOKOUT_SIGN_IDENTITY to choose a different identity.
# Use the certificate's hash, not its name: expired certificates with the same
# name stay in the keychain and would make the name ambiguous.
identity="${LOOKOUT_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
  | sed -n 's/^ *[0-9]*) \([0-9A-F]\{40\}\) "Apple Development: .*/\1/p' | head -1)}"
if [ -n "$identity" ]; then
  codesign --force --sign "$identity" "$app"
  echo "Signed with: $identity"
else
  codesign --force --sign - "$app"
  echo "Signed ad hoc: notifications won't work until an Apple Development certificate exists"
fi

echo "Built $app"
