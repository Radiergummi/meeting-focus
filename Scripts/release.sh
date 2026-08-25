#!/bin/bash
#
# Builds a signed, notarized, stapled MeetingFocus.dmg for distribution via GitHub Releases.
#
# Notarization needs credentials that only you can create. Store them once as a keychain profile:
#
#   xcrun notarytool store-credentials MeetingFocus-Notary \
#       --apple-id "you@example.com" \
#       --team-id TH593VRB6W \
#       --password "<app-specific-password>"
#
# Then:  ./Scripts/release.sh
#        ./Scripts/release.sh --skip-notarize     (local test builds only — do not ship these)
#
set -euo pipefail

cd "$(dirname "$0")/.."

PROFILE="${NOTARY_PROFILE:-MeetingFocus-Notary}"
SKIP_NOTARIZE=0
[[ "${1:-}" == "--skip-notarize" ]] && SKIP_NOTARIZE=1

BUILD_DIR="build"
ARCHIVE="$BUILD_DIR/MeetingFocus.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP="$EXPORT_DIR/MeetingFocus.app"
STAGE="$BUILD_DIR/dmg"

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

step "Regenerating the Xcode project"
command -v xcodegen >/dev/null || { echo "xcodegen not installed: brew install xcodegen" >&2; exit 1; }
xcodegen generate

step "Running tests"
xcodebuild -project MeetingFocus.xcodeproj -scheme MeetingFocusCoreTests \
    -destination 'platform=macOS' test | tail -3

step "Archiving"
rm -rf "$ARCHIVE" "$EXPORT_DIR" "$STAGE"
xcodebuild -project MeetingFocus.xcodeproj -scheme MeetingFocus \
    -configuration Release -archivePath "$ARCHIVE" archive | tail -3

step "Exporting with Developer ID"
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
    -exportOptionsPlist Scripts/ExportOptions.plist \
    -exportPath "$EXPORT_DIR" | tail -3

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="$BUILD_DIR/MeetingFocus-$VERSION.dmg"

step "Verifying the signature"
codesign --verify --deep --strict --verbose=2 "$APP"
# Hardened runtime and a secure timestamp are both prerequisites for notarization; check now
# rather than discovering it after a round trip to Apple. The output is captured first because
# `grep -q` exits on the first match, which SIGPIPEs codesign and trips `pipefail`.
SIGN_INFO=$(codesign -d --verbose=4 "$APP" 2>&1 || true)
grep -q 'flags=.*runtime' <<<"$SIGN_INFO" \
    || { echo "hardened runtime is not enabled" >&2; exit 1; }
grep -q 'Authority=Developer ID Application' <<<"$SIGN_INFO" \
    || { echo "not signed with a Developer ID Application certificate" >&2; exit 1; }
grep -q 'Timestamp=' <<<"$SIGN_INFO" \
    || { echo "signature has no secure timestamp; notarization will be rejected" >&2; exit 1; }

if [[ $SKIP_NOTARIZE -eq 0 ]]; then
    step "Notarizing (this waits on Apple, usually a few minutes)"
    if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
        cat >&2 <<EOF
No notarization credentials found for keychain profile "$PROFILE".
Create them once with:

  xcrun notarytool store-credentials $PROFILE \\
      --apple-id "you@example.com" --team-id TH593VRB6W \\
      --password "<app-specific-password>"

Or pass --skip-notarize to build an unnotarized local artifact.
EOF
        exit 1
    fi
    ZIP="$BUILD_DIR/MeetingFocus-notarize.zip"
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
    xcrun stapler staple "$APP"
    rm -f "$ZIP"
else
    step "Skipping notarization (local build — Gatekeeper will warn on other machines)"
fi

step "Building the disk image"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "MeetingFocus $VERSION" -srcfolder "$STAGE" \
    -ov -format UDZO "$DMG" >/dev/null

step "Done"
echo "$DMG"
if [[ $SKIP_NOTARIZE -eq 0 ]]; then
    spctl --assess --type open --context context:primary-signature -v "$DMG" 2>&1 || true
fi
