#!/bin/bash
#
# Checks the things that must agree before you push a release tag.
#
#   ./Scripts/preflight.sh 0.1.1
#
# The release workflow already refuses to sign anything when the tag, project.yml and CHANGELOG.md
# disagree — so this changes no outcome, it only moves the failure to before the tag exists. That is
# worth a script because recovering afterwards means deleting a pushed tag:
#
#   git tag -d v0.1.1 && git push --delete origin v0.1.1
#
# which is the most irritating part of getting a release wrong.
#
# Deliberately does NOT bump the version, edit the CHANGELOG, commit, tag or push. Those steps
# involve editorial judgement and the git remote, and one release has been cut so far — automating
# them now would encode guesses about which parts actually chafe.
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
    echo "usage: $(basename "$0") <version>        e.g. 0.1.1" >&2
    exit 2
fi
TAG="v$VERSION"
failures=0

note() { printf '  %-8s %s\n' "$1" "$2"; }
fail() { note "FAIL" "$1"; failures=$((failures + 1)); }

echo "preflight for $TAG"

# 1. project.yml is what stamps the bundle, so a mismatch ships a build whose version is not the one
#    it was tagged as. The workflow checks this too, and independently.
plist_version=$(grep -m1 'MARKETING_VERSION:' project.yml | sed 's/.*"\(.*\)".*/\1/')
if [[ "$plist_version" == "$VERSION" ]]; then
    note "ok" "project.yml MARKETING_VERSION is $plist_version"
else
    fail "project.yml MARKETING_VERSION is $plist_version, expected $VERSION"
fi

# 2. Release notes. Shared with the workflow — see Scripts/release-notes.sh.
if notes=$(./Scripts/release-notes.sh "$VERSION" 2>/dev/null); then
    note "ok" "CHANGELOG.md has $(printf '%s' "$notes" | grep -c '[^[:space:]]') line(s) for $VERSION"
else
    fail "CHANGELOG.md has no '## [$VERSION]' section — the workflow stops on this"
fi

# 3. A tag that already exists is either a re-release you did not mean, or a tag pointing somewhere
#    other than where you think.
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    fail "$TAG already exists locally"
elif git ls-remote --exit-code --tags origin "$TAG" >/dev/null 2>&1; then
    fail "$TAG already exists on origin"
else
    note "ok" "$TAG is unused"
fi

# 4. `git tag` tags HEAD, so uncommitted work is simply not in the release — and that is invisible
#    at the moment you tag.
if [[ -n "$(git status --porcelain)" ]]; then
    fail "working tree is dirty; the tag would not include those changes"
else
    note "ok" "working tree is clean"
fi

echo
if (( failures > 0 )); then
    echo "$failures check(s) failed — fix them before tagging."
    exit 1
fi
cat <<EOF
ready. To release:

  git tag $TAG && git push origin $TAG

The workflow builds, notarizes, attests and opens a DRAFT release. Publish it by hand, then run
'make publish' locally to sign the appcast — CI never holds the Sparkle key.
EOF
