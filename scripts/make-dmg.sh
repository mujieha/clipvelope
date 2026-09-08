#!/bin/bash
# Builds dist/Clipvelope-<version>.dmg: the app plus a drag-to-Applications link.
#
# The DMG is signed with the same identity as the app when one is available.
# Apple notarizes the disk image as well as the app inside it, and a stapled
# ticket on the DMG is what lets a downloaded copy pass Gatekeeper offline.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=dist/Clipvelope.app
STAGING=dist/dmg-staging

if [ "${SKIP_BUILD:-no}" != yes ]; then
    ./scripts/bundle.sh
fi

if [ ! -d "$APP" ]; then
    echo "error: $APP is missing; run ./scripts/bundle.sh first" >&2
    exit 1
fi

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
          "$APP/Contents/Info.plist")
DMG="dist/Clipvelope-${version}.dmg"

rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

hdiutil create \
    -volname "Clipvelope ${version}" \
    -srcfolder "$STAGING" \
    -fs HFS+ \
    -format UDZO \
    -quiet \
    "$DMG"
rm -rf "$STAGING"

# Sign the image itself. An unsigned DMG can still carry a notarization ticket,
# but signing it means the download is tamper-evident before it is ever opened.
identity="${CODESIGN_IDENTITY:-}"
if [ -z "$identity" ]; then
    identities=$(security find-identity -v -p codesigning 2>/dev/null \
                 | sed -n 's/^ *[0-9]*) [0-9A-F]* "\(.*\)"$/\1/p')
    [ "$(printf '%s' "$identities" | grep -c . || true)" = "1" ] && identity="$identities"
fi

if [ -n "$identity" ] && [ "$identity" != "-" ]; then
    codesign --force --sign "$identity" --timestamp "$DMG"
    echo "signed the image with $identity"
else
    echo "note: the image is unsigned. Notarization needs a Developer ID identity;"
    echo "      see docs/DISTRIBUTION.md."
fi

# Prove the thing actually opens and holds what it should, rather than trusting
# that hdiutil succeeded.
mountpoint=$(mktemp -d)
hdiutil attach "$DMG" -mountpoint "$mountpoint" -nobrowse -quiet
if [ ! -x "$mountpoint/Clipvelope.app/Contents/MacOS/Clipvelope" ]; then
    hdiutil detach "$mountpoint" -quiet || true
    echo "error: the image does not contain a usable Clipvelope.app" >&2
    exit 1
fi
if [ ! -L "$mountpoint/Applications" ]; then
    hdiutil detach "$mountpoint" -quiet || true
    echo "error: the image has no /Applications shortcut to drag onto" >&2
    exit 1
fi
hdiutil detach "$mountpoint" -quiet
rmdir "$mountpoint" 2>/dev/null || true

echo
echo "built $DMG ($(du -h "$DMG" | cut -f1))"
