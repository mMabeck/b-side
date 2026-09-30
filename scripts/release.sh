#!/bin/bash
# Bumps VERSION, commits it on main and creates the matching annotated tag.
# Pushing the tag is left to you; it triggers .github/workflows/release.yml.
set -euo pipefail

usage() {
    echo "usage: $0 major|minor|patch|X.Y.Z[-prerelease]" >&2
    exit 2
}
[ $# -eq 1 ] || usage

cd "$(dirname "$0")/.."

SEMVER='^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'
CURRENT="$(cat VERSION)"
IFS=. read -r MAJOR MINOR PATCH <<<"${CURRENT%%-*}"

case "$1" in
    major) NEXT="$((MAJOR + 1)).0.0" ;;
    minor) NEXT="$MAJOR.$((MINOR + 1)).0" ;;
    patch) NEXT="$MAJOR.$MINOR.$((PATCH + 1))" ;;
    *) [[ "$1" =~ $SEMVER ]] || usage; NEXT="$1" ;;
esac
TAG="v$NEXT"

if [ "$(git branch --show-current)" != "main" ]; then
    echo "error: releases are cut from main" >&2
    exit 1
fi
if [ -n "$(git status --porcelain)" ]; then
    echo "error: working tree is not clean" >&2
    exit 1
fi
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    echo "error: tag $TAG already exists" >&2
    exit 1
fi
core_number() {
    IFS=. read -r major minor patch <<<"${1%%-*}"
    echo $((major * 1000000 + minor * 1000 + patch))
}
CURRENT_CORE="$(core_number "$CURRENT")"
NEXT_CORE="$(core_number "$NEXT")"
# A pre-release may be followed by its own final release or a later pre-release.
if [ "$NEXT_CORE" -lt "$CURRENT_CORE" ] || { [ "$NEXT_CORE" -eq "$CURRENT_CORE" ] && [[ "$CURRENT" != *-* ]]; }; then
    echo "error: $NEXT is not newer than $CURRENT" >&2
    exit 1
fi

echo "$NEXT" > VERSION
git commit -q -m "chore(release): $TAG" VERSION
git tag -a "$TAG" -m "B-Side $NEXT"

echo "Tagged $TAG. Publish with:"
echo "  git push origin main $TAG"
