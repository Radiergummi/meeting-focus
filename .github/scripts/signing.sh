#!/bin/bash
#
# Installs the release signing material into a throwaway keychain on the CI runner.
#
# Adapted from Secretive, whose release process this project's trust model follows: releases are
# built by a public runner from a public commit so that what users download can be traced back to
# source they can read, rather than to a laptop nobody can inspect.
#
# The trade this makes is deliberate and worth naming: the Developer ID signing key has to exist
# on the runner for the duration of the build. It lives in an ephemeral keychain on a throwaway VM,
# and the alternative — signing on a developer machine — buys key isolation at the cost of every
# user having to trust an unverifiable binary. Public provenance is judged the better trade here.
#
set -euo pipefail

: "${SIGNING_DATA:?missing SIGNING_DATA secret (base64 of the Developer ID .p12)}"
: "${SIGNING_PASSWORD:?missing SIGNING_PASSWORD secret}"
: "${APPLE_API_KEY_DATA:?missing APPLE_API_KEY_DATA secret (App Store Connect .p8)}"
: "${APPLE_API_KEY_ID:?missing APPLE_API_KEY_ID secret}"

KEYCHAIN="ci.keychain"
KEYCHAIN_PASSWORD="ci"

echo "$SIGNING_DATA" | base64 -d -o Signing.p12

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security default-keychain -s "$KEYCHAIN"
security list-keychains -s "$KEYCHAIN"
# Without unlocking, codesign prompts — which on a headless runner means hanging until timeout.
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 3600 "$KEYCHAIN"
security import ./Signing.p12 -k "$KEYCHAIN" -P "$SIGNING_PASSWORD" -A -T /usr/bin/codesign
# Grants codesign non-interactive access to the imported key; without it every signing call blocks
# on a UI prompt that cannot appear.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
rm -f Signing.p12

# notarytool reads the App Store Connect key from disk by id.
mkdir -p ~/.private_keys
printf '%s' "$APPLE_API_KEY_DATA" > ~/".private_keys/AuthKey_${APPLE_API_KEY_ID}.p8"

echo "signing identities available:"
security find-identity -v -p codesigning | grep "Developer ID Application" || {
    echo "no Developer ID Application identity was imported" >&2
    exit 1
}
