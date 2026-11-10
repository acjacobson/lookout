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
cp Support/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"  # made by scripts/make-icon.swift
# Also compile the icon into an asset catalog (Assets.car), named by CFBundleIconName
# in Info.plist. macOS 26 Notification Center shows a blank icon for an app that has
# only the .icns file. actool comes with Xcode; without it the .icns is used alone.
if xcrun --find actool >/dev/null 2>&1; then
  work=$(mktemp -d)
  iconutil -c iconset Support/AppIcon.icns -o "$work/AppIcon.iconset"
  set_dir="$work/Assets.xcassets/AppIcon.appiconset"
  mkdir -p "$set_dir"
  printf '{"info":{"version":1,"author":"xcode"}}' >"$work/Assets.xcassets/Contents.json"
  images=""
  for base in 16 32 128 256 512; do
    for scale in 1 2; do
      if [ "$scale" = 1 ]; then f="icon_${base}x${base}.png"; else f="icon_${base}x${base}@2x.png"; fi
      cp "$work/AppIcon.iconset/$f" "$set_dir/$f"
      images="$images{\"idiom\":\"mac\",\"size\":\"${base}x${base}\",\"scale\":\"${scale}x\",\"filename\":\"$f\"},"
    done
  done
  printf '{"images":[%s],"info":{"version":1,"author":"xcode"}}' "${images%,}" >"$set_dir/Contents.json"
  xcrun actool "$work/Assets.xcassets" --compile "$app/Contents/Resources" --platform macosx \
    --minimum-deployment-target 13.0 --app-icon AppIcon \
    --output-partial-info-plist "$work/partial.plist" >/dev/null
  rm -rf "$work"
fi
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
