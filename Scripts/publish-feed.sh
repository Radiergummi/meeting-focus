#!/bin/bash
#
# Deploys the Sparkle appcast to the Cloudflare Worker at meetingfocus.mazetti.me.
#
# Run this *after* the GitHub release assets are attached. Publishing a feed whose enclosure URL
# does not resolve would advertise an update that every client fails to download, so this refuses
# to deploy until the asset is actually reachable.
#
set -euo pipefail
cd "$(dirname "$0")/.."

FEED_URL="https://meetingfocus.mazetti.me/appcast.xml"
APPCAST="worker/public/appcast.xml"

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

[[ -f "$APPCAST" ]] || { echo "$APPCAST not found — run Scripts/release.sh first" >&2; exit 1; }

step "Checking the appcast"
grep -q 'sparkle:edSignature' "$APPCAST" \
    || { echo "appcast carries no EdDSA signature; clients would reject the update" >&2; exit 1; }

# Every enclosure is checked, not just the newest: an older entry pointing at a deleted asset
# breaks updates for anyone still running that version.
URLS=$(grep -o 'url="[^"]*"' "$APPCAST" | sed 's/url="//;s/"//')
[[ -n "$URLS" ]] || { echo "appcast contains no enclosure URLs" >&2; exit 1; }

while read -r url; do
    printf '  %s ... ' "$url"
    code=$(curl -sSL -o /dev/null -w '%{http_code}' --max-time 30 "$url" || echo 000)
    if [[ "$code" == "200" ]]; then
        echo "ok"
    else
        echo "HTTP $code"
        echo "refusing to publish: that download is not reachable." >&2
        echo "Attach the asset to its GitHub release first." >&2
        exit 1
    fi
done <<< "$URLS"

step "Deploying the Worker"
(cd worker && npx --yes wrangler@latest deploy)

step "Verifying the published feed"
sleep 3
published=$(curl -sS --max-time 20 "$FEED_URL")
type=$(curl -sS -o /dev/null -w '%{content_type}' --max-time 20 "$FEED_URL")
grep -q 'sparkle:edSignature' <<<"$published" \
    || { echo "the published feed carries no signature" >&2; exit 1; }
[[ "$type" == application/xml* ]] \
    || { echo "unexpected Content-Type: $type (Sparkle needs XML)" >&2; exit 1; }
echo "$FEED_URL is live and signed ($type)"
