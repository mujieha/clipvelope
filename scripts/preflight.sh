#!/bin/bash
# Refuses a release the tree is not ready for. Read-only: safe to run at any
# time, and `make preflight` is the first step of the release recipe.
#
# Three traps have already cost real work on this project, and two of them are
# silent:
#
#   - A stale image left in dist/ was nearly signed into the update feed.
#   - CFBundleVersion is what Sparkle compares, not the version string. A 0.2.0
#     built with the build number still at 1 is never offered to anyone running
#     0.1.0, and Sparkle reports nothing - the app looks like it is current.
#   - The changelog is the release notes, in the update prompt and on the
#     release page, so a version with no section ships an update that says
#     nothing.
#
# Every check runs; the script reports all of them and exits 1 if any failed,
# because a person reading this output is deciding whether to ship.
set -euo pipefail
cd "$(dirname "$0")/.."

PLIST=Resources/Info.plist

status=0
ok()   { echo "ok:   $*"; }
skip() { echo "skip: $*"; }
fail() { echo "FAIL: $*"; status=1; }

# PlistBuddy exits non-zero for a key that is absent, which is a result here
# rather than an error, so absence must not trip `set -e`.
plist_get() {
    /usr/libexec/PlistBuddy -c "Print :$1" "$2" 2>/dev/null || true
}

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

version=$(plist_get CFBundleShortVersionString "$PLIST")
build=$(plist_get CFBundleVersion "$PLIST")
echo "Clipvelope $version (build $build)"
echo

# --- the deployment target lives in two places -------------------------------
# CI checks this too, but preflight is what a human runs before a release, so it
# repeats the check rather than sending them to a workflow log. Read from the
# manifest rather than `swift package describe`, which resolves dependencies and
# writes to .build; this script must stay read-only and instant.
pkg_platform=$(sed -n 's/.*\.macOS("\([^"]*\)").*/\1/p' Package.swift | head -1)
plist_platform=$(plist_get LSMinimumSystemVersion "$PLIST")
if [ -z "$pkg_platform" ]; then
    fail "could not read the macOS platform version from Package.swift"
elif [ "$pkg_platform" != "$plist_platform" ]; then
    fail "deployment targets disagree: Package.swift=$pkg_platform $PLIST=$plist_platform"
else
    ok "deployment targets agree ($pkg_platform)"
fi

# --- the changelog is the release notes --------------------------------------
if [ -z "$version" ]; then
    fail "$PLIST has no CFBundleShortVersionString"
elif ! grep -q "^## ${version}\$" CHANGELOG.md; then
    fail "CHANGELOG.md has no '## $version' section; the update prompt would say nothing"
else
    notes=$(awk -v want="## $version" '
        $0 == want { inside = 1; next }
        inside && /^## / { exit }
        inside { print }
    ' CHANGELOG.md)
    if [ -z "$(printf '%s' "$notes" | tr -d '[:space:]')" ]; then
        fail "the '## $version' section of CHANGELOG.md is empty"
    else
        ok "CHANGELOG.md has a '## $version' section with release notes"
    fi
fi

# --- the build number Sparkle actually compares ------------------------------
is_integer() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

if ! is_integer "$build"; then
    fail "CFBundleVersion '$build' is not an integer; Sparkle compares it numerically"
else
    tag=$(git tag --list 'v*' --sort=-v:refname | head -1)
    if [ -z "$tag" ]; then
        skip "no release tag yet, so there is no build number to be ahead of"
    else
        # PlistBuddy needs a file on disk, so the tagged plist is written out.
        git show "$tag:$PLIST" > "$TMP"
        tagged_version=$(plist_get CFBundleShortVersionString "$TMP")
        tagged_build=$(plist_get CFBundleVersion "$TMP")
        if [ "$version" = "$tagged_version" ]; then
            skip "version is still $version, the one $tag shipped: nothing has been bumped yet"
        elif ! is_integer "$tagged_build"; then
            fail "$tag shipped CFBundleVersion '$tagged_build', which is not an integer"
        elif [ "$build" -le "$tagged_build" ]; then
            fail "CFBundleVersion $build must be greater than $tagged_build, which $tag shipped; Sparkle would never offer this update and would say nothing"
        else
            ok "CFBundleVersion $build is ahead of $tagged_build, which $tag shipped"
        fi
    fi
fi

# --- the updater needs its key and its feed ----------------------------------
for key in SUPublicEDKey SUFeedURL; do
    value=$(plist_get "$key" "$PLIST")
    if [ -z "$value" ]; then
        fail "$key is missing or empty in $PLIST; the updater cannot work without it"
    else
        ok "$key is set"
    fi
done

# --- dist/ must not hold a stale image ---------------------------------------
shopt -s nullglob
images=(dist/*.dmg)
shopt -u nullglob
if [ "${#images[@]}" -eq 0 ]; then
    ok "dist/ holds no disk image yet"
elif [ "${#images[@]}" -gt 1 ]; then
    fail "dist/ holds ${#images[@]} disk images; make appcast would sign all of them: ${images[*]}"
else
    image_version=$(basename "${images[0]}" .dmg)
    image_version=${image_version##*-}
    if [ "$image_version" != "$version" ]; then
        fail "${images[0]} is version $image_version but the tree is $version; remove the stale image"
    else
        ok "dist/ holds one disk image, ${images[0]}"
    fi
fi

# --- a release built from a dirty tree cannot be reproduced ------------------
dirty=$(git status --porcelain --untracked-files=no)
if [ -z "$dirty" ]; then
    ok "the working tree is clean"
elif [ "${PREFLIGHT_ALLOW_DIRTY:-0}" = 1 ]; then
    skip "the working tree has uncommitted changes; PREFLIGHT_ALLOW_DIRTY=1 is set"
else
    fail "the working tree has uncommitted changes, so this build could not be reproduced:"
    printf '%s\n' "$dirty" | sed 's/^/        /'
    echo "      set PREFLIGHT_ALLOW_DIRTY=1 to continue anyway"
fi

echo
if [ "$status" -eq 0 ]; then
    echo "preflight: ready to release $version (build $build)"
else
    echo "preflight: NOT ready to release; fix the FAIL lines above"
fi
exit "$status"
