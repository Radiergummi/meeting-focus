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
SKIP_APPCAST=0
for arg in "$@"; do
    case "$arg" in
        --skip-notarize) SKIP_NOTARIZE=1 ;;
        # CI builds and attests the artifact but does not sign the update feed: the Sparkle private
        # key stays on the maintainer's machine, so the build attestation and the update
        # authorisation are two independent signatures rather than one key that can do both.
        --skip-appcast)  SKIP_APPCAST=1 ;;
        *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done

# notarytool takes either a stored keychain profile (local) or an App Store Connect key on disk
# (CI, where there is no keychain profile to store).
if [[ -n "${NOTARY_KEY_ID:-}" ]]; then
    NOTARY_ARGS=(--key "${NOTARY_KEY_PATH:-$HOME/.private_keys/AuthKey_${NOTARY_KEY_ID}.p8}"
                 --key-id "$NOTARY_KEY_ID"
                 --issuer "${NOTARY_ISSUER:?NOTARY_ISSUER is required alongside NOTARY_KEY_ID}")
else
    NOTARY_ARGS=(--keychain-profile "$PROFILE")
fi

# Provenance stamped into the bundle, so a copy can say where it came from. The defaults describe
# a local build honestly rather than claiming a provenance it does not have.
BUILD_SETTINGS=(MF_BUILD_COMMIT="${MF_BUILD_COMMIT:-local}" MF_BUILD_RUN_URL="${MF_BUILD_RUN_URL:-}")

# Sparkle decides what is newer by CFBundleVersion, not by the marketing version. Two releases
# sharing a build number are therefore the *same* update to an installed copy: generate_appcast
# rewrites the existing entry instead of adding one, and the older release disappears from the feed.
# CI passes its run number, which is monotonic; a local build keeps whatever project.yml says.
#
# Passed as a build setting rather than exported, because xcodebuild takes settings from its command
# line and not from the environment — an env var here looks like it works and silently does nothing.
if [[ -n "${CURRENT_PROJECT_VERSION:-}" ]]; then
    BUILD_SETTINGS+=(CURRENT_PROJECT_VERSION="$CURRENT_PROJECT_VERSION")
fi

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
# Signed with Developer ID here rather than left to automatic signing. Automatic signing resolves
# the *archive* to a development certificate — a build-time input that export then re-signs and
# discards, but which must still exist. On a developer's machine it always does, so the requirement
# is invisible; on a clean runner holding only the Developer ID key it fails the archive outright,
# which is exactly how it was found. This script only ever produces something to distribute, so the
# distribution certificate is the honest input at every step.
xcodebuild -project MeetingFocus.xcodeproj -scheme MeetingFocus \
    -configuration Release -archivePath "$ARCHIVE" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    "${BUILD_SETTINGS[@]}" archive | tail -3

step "Exporting with Developer ID"
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
    -exportOptionsPlist Scripts/ExportOptions.plist \
    -exportPath "$EXPORT_DIR" | tail -3

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="$BUILD_DIR/MeetingFocus-$VERSION.dmg"
# A writable intermediate, discarded once the compressed image is built. See below for why.
RW_DMG="$BUILD_DIR/MeetingFocus-$VERSION-rw.dmg"

# Checked before notarization rather than after: a round trip to Apple takes minutes, and this
# failure is knowable the moment the bundle exists. A build number that is not newer than the one
# already advertised cannot be offered as an update to anyone running the published version.
step "Checking the build number is newer than the published one"
BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")
PUBLISHED_BUILD=$(curl -fsSL "$FEED_URL" 2>/dev/null \
    | sed -n 's/.*<sparkle:version>\([0-9][0-9]*\)<.*/\1/p' | sort -n | tail -1)
if [[ -z "$PUBLISHED_BUILD" ]]; then
    echo "no published feed to compare against; build number is $BUILD_NUMBER"
elif [[ "$BUILD_NUMBER" -le "$PUBLISHED_BUILD" ]]; then
    echo "build number $BUILD_NUMBER is not newer than the published $PUBLISHED_BUILD." >&2
    echo "Sparkle compares CFBundleVersion, so this build could not be offered as an update," >&2
    echo "and generate_appcast would overwrite the existing entry rather than add one." >&2
    exit 1
else
    echo "build $BUILD_NUMBER supersedes the published $PUBLISHED_BUILD"
fi

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
    if ! xcrun notarytool history "${NOTARY_ARGS[@]}" >/dev/null 2>&1; then
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
    xcrun notarytool submit "$ZIP" "${NOTARY_ARGS[@]}" --wait
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
# The mounted volume shows the app's own icon rather than the generic disk image. actool writes
# this .icns beside Assets.car when it compiles Icons/MeetingFocus.icon, so the download and the
# app it carries come from one drawing — nothing here to redraw when the icon changes.
cp "$APP/Contents/Resources/MeetingFocus.icns" "$STAGE/.VolumeIcon.icns"
rm -f "$DMG" "$RW_DMG"
# Finder only reads .VolumeIcon.icns when the volume carries the custom-icon flag, and that flag
# can only be set on a mounted, writable volume. Hence read-write first, flag it, then compress —
# a UDZO image created directly would carry the file and ignore it.
hdiutil create -volname "MeetingFocus $VERSION" -srcfolder "$STAGE" \
    -ov -format UDRW "$RW_DMG" >/dev/null
MOUNT=$(hdiutil attach "$RW_DMG" -nobrowse -noverify | grep -o '/Volumes/.*' | head -1)
[[ -n "$MOUNT" ]] || { echo "could not mount $RW_DMG" >&2; exit 1; }
SetFile -a C "$MOUNT"
hdiutil detach "$MOUNT" >/dev/null
hdiutil convert "$RW_DMG" -format UDZO -o "$DMG" >/dev/null
rm -f "$RW_DMG"

# The disk image needs its own signature and ticket. Stapling only the app leaves the download
# itself unsigned, which Gatekeeper reports as "no usable signature" when the DMG is assessed.
IDENTITY=$(security find-identity -v -p codesigning \
    | grep "Developer ID Application" | grep "$TEAM_ID" | head -1 \
    | sed -E 's/.*"(.*)".*/\1/')
[[ -n "$IDENTITY" ]] || { echo "no Developer ID Application identity for team $TEAM_ID" >&2; exit 1; }
codesign --force --sign "$IDENTITY" --timestamp "$DMG"

if [[ $SKIP_NOTARIZE -eq 0 ]]; then
    step "Notarizing the disk image"
    xcrun notarytool submit "$DMG" "${NOTARY_ARGS[@]}" --wait
    xcrun stapler staple "$DMG"
fi

if [[ $SKIP_APPCAST -eq 1 ]]; then
    step "Done (appcast skipped)"
    echo "disk image: $DMG"
    exit 0
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
