#!/bin/bash
#
# Produces a signed, notarized, stapled EchoScribe-<version>.dmg plus a stapled
# EchoScribe.app ready to copy into /Applications.
#
# Adapted from rapple's release.sh, same robust ordering: the app is notarized
# and **stapled before** it goes into the DMG, so it launches cleanly even on a
# first run with no network; then the DMG itself is signed, notarized, and
# stapled so the download is clean too. Two notarization round-trips.
#
# Prerequisites (one-time):
#   • A "Developer ID Application" certificate in the login keychain.
#   • A notarytool keychain profile (xcrun notarytool store-credentials …).
#     Profiles are tied to the Apple ID/team, not to an app, so any existing
#     profile works.
#
# Usage (defaults match this machine; override via env):
#   [DEVELOPER_ID_APP="Developer ID Application: Name (TEAMID)"] \
#   [NOTARY_PROFILE="profile-name"] scripts/release.sh
#
set -euo pipefail
cd "$(dirname "$0")/.."

DEVELOPER_ID_APP="${DEVELOPER_ID_APP:-Developer ID Application: TIMOTHY SCHUYLER VANBENSCHOTEN (U44N9ZPFP2)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-rapple-notary}"
ENTITLEMENTS="Packaging/EchoScribe.entitlements"

echo "==> Generating Xcode project"
xcodegen generate

echo "==> Building Release"
xcodebuild build -project EchoScribe.xcodeproj -scheme EchoScribe \
  -configuration Release -derivedDataPath build CODE_SIGNING_ALLOWED=NO -quiet

APP="build/Build/Products/Release/EchoScribe.app"
[ -d "$APP" ] || { echo "✗ Built app not found at $APP"; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="EchoScribe-${VERSION}.dmg"

# Hardened Runtime + secure timestamp are required for notarization; the
# entitlements file re-grants mic + Reminders access under the hardened runtime.
echo "==> Signing app with Developer ID"
codesign --force --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" --sign "$DEVELOPER_ID_APP" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "==> Notarizing app (round 1 of 2; can take a few minutes)"
WORK="$(mktemp -d)"
/usr/bin/ditto -c -k --keepParent "$APP" "$WORK/EchoScribe.zip"
xcrun notarytool submit "$WORK/EchoScribe.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
rm -rf "$WORK"

echo "==> Building $DMG from the stapled app"
rm -rf "$DMG" build/dmg-staging
mkdir -p build/dmg-staging
cp -R "$APP" build/dmg-staging/
ln -s /Applications build/dmg-staging/Applications
hdiutil create -volname "EchoScribe" -srcfolder build/dmg-staging -ov -format UDZO "$DMG"
rm -rf build/dmg-staging

echo "==> Signing DMG"
codesign --force --timestamp --sign "$DEVELOPER_ID_APP" "$DMG"
echo "==> Notarizing DMG (round 2 of 2)"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"

echo "==> Verifying"
spctl -a -vv "$APP"
spctl -a -t open --context context:primary-signature -v "$DMG" || true
echo "==> Done:"
echo "    app: $(pwd)/$APP   (stapled — copy this to /Applications)"
echo "    dmg: $(pwd)/$DMG"
