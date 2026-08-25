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
REPO="Radiergummi/meeting-focus"
TEAM_ID="TH593VRB6W"
FEED_URL="https://meetingfocus.mazetti.me/appcast.xml"
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
    step "Notarizing the app (this waits on Apple, usually a few minutes)"
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
    # Staple the app itself, so it stays trusted once dragged out of the disk image.
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

# The disk image needs its own signature and ticket. Stapling only the app leaves the download
# itself unsigned, which Gatekeeper reports as "no usable signature" when the DMG is assessed.
IDENTITY=$(security find-identity -v -p codesigning \
    | grep "Developer ID Application" | grep "$TEAM_ID" | head -1 \
    | sed -E 's/.*"(.*)".*/\1/')
[[ -n "$IDENTITY" ]] || { echo "no Developer ID Application identity for team $TEAM_ID" >&2; exit 1; }
codesign --force --sign "$IDENTITY" --timestamp "$DMG"

if [[ $SKIP_NOTARIZE -eq 0 ]]; then
    step "Notarizing the disk image"
    xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
    xcrun stapler staple "$DMG"
fi

step "Generating the Sparkle appcast"
# generate_appcast ships inside Sparkle's SPM artifact bundle; its location is derived rather than
# hardcoded because the DerivedData path contains a build-specific hash.
GENERATE_APPCAST=$(find ~/Library/Developer/Xcode/DerivedData/MeetingFocus-*/SourcePackages/artifacts/sparkle \
    -name generate_appcast -type f 2>/dev/null | head -1)
if [[ -z "$GENERATE_APPCAST" ]]; then
    echo "generate_appcast not found — run: xcodebuild -resolvePackageDependencies" >&2
    exit 1
fi

UPDATES="$BUILD_DIR/updates"
mkdir -p "$UPDATES"
cp "$DMG" "$UPDATES/"

# Seed from the published appcast so previously released versions keep their own entries.
# generate_appcast preserves existing items, so without this an appcast regenerated on a clean
# checkout would silently drop older versions.
curl -fsSL "$FEED_URL" -o "$UPDATES/appcast.xml" 2>/dev/null \
    && echo "seeded from the published appcast" \
    || echo "no published appcast yet (first release, or the site is not up)"

# A version-pinned prefix, not releases/latest/download: "latest" would make every entry in the
# appcast — including older ones — resolve to the newest asset.
# generate_appcast only rewrites new items, so earlier entries keep the URLs they were built with.
"$GENERATE_APPCAST" "$UPDATES" \
    --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/"

# Signed with the EdDSA private key from the login keychain. A missing-key error here means the
# signing key was never generated or has been lost — see README.
grep -q 'sparkle:edSignature' "$UPDATES/appcast.xml" \
    || { echo "appcast has no EdDSA signature; updates would be rejected" >&2; exit 1; }

# Staged for the feed, but deliberately not deployed here: publishing the appcast before the
# release assets exist would advertise an update whose download 404s. Scripts/publish-feed.sh
# checks the enclosure URLs are reachable first.
cp "$UPDATES/appcast.xml" worker/public/appcast.xml

step "Done"
echo "disk image: $DMG"
echo "appcast:    $UPDATES/appcast.xml (staged at worker/public/appcast.xml)"
echo
echo "To publish, in this order:"
echo "  1. gh release create v$VERSION \"$DMG\" --repo $REPO --title \"MeetingFocus $VERSION\""
echo "  2. ./Scripts/publish-feed.sh        # verifies the download, then deploys the feed"
if [[ $SKIP_NOTARIZE -eq 0 ]]; then
    step "Verifying Gatekeeper acceptance"
    spctl --assess --type exec -v "$APP" || { echo "the app was rejected by Gatekeeper" >&2; exit 1; }
    spctl --assess --type open --context context:primary-signature -v "$DMG" \
        || { echo "the disk image was rejected by Gatekeeper" >&2; exit 1; }
    echo "app and disk image both accepted"
fi
