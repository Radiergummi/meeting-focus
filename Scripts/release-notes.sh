#!/bin/bash
#
# Prints the CHANGELOG.md section for one version, and fails if there is not one.
#
#   ./Scripts/release-notes.sh 0.1.1
#   ./Scripts/release-notes.sh Unreleased
#
# This exists so that .github/workflows/release.yml and Scripts/preflight.sh run the SAME
# extraction rather than two copies of the same awk. The rule it encodes — where a section starts
# and where it stops — is the kind that gets edited in one place and forgotten in the other, and it
# lived inline in the workflow's YAML at first, which is the least testable place in the repo.
#
# Note what is deliberately NOT shared: the one-line `MARKETING_VERSION` comparison is repeated in
# the workflow and in preflight. That is defence in depth, not duplication to fix — CI must check it
# independently, because it cannot assume anybody ran preflight.
set -euo pipefail

cd "$(dirname "$0")/.."

CHANGELOG="CHANGELOG.md"
VERSION="${1:-}"

if [[ -z "$VERSION" ]]; then
    echo "usage: $(basename "$0") <version>        e.g. 0.1.1, or Unreleased" >&2
    exit 2
fi

if [[ ! -f "$CHANGELOG" ]]; then
    echo "$CHANGELOG does not exist" >&2
    exit 1
fi

# Stops at the next heading, and at the link reference definitions at the foot of the file —
# otherwise the final section's extraction swallows them.
section=$(awk -v version="$VERSION" '
    $0 ~ "^## \\[" version "\\]" { found = 1; next }
    found && /^## / { exit }
    found && /^\[[^]]+\]: / { exit }
    found { print }
' "$CHANGELOG")

if ! printf '%s' "$section" | grep -q '[^[:space:]]'; then
    echo "$CHANGELOG has no entry for $VERSION." >&2
    echo "Add a '## [$VERSION] — <date>' section describing what changed, then try again." >&2
    exit 1
fi

printf '%s\n' "$section"
