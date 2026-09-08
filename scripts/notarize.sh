#!/bin/bash
# Notarizes and staples a built app or disk image.
#
#   ./scripts/notarize.sh dist/Clipvelope-0.1.0.dmg
#
# Credentials come from a notarytool keychain profile, so no secret is ever
# passed on a command line or stored in this repository. Create one once:
#
#   xcrun notarytool store-credentials Clipvelope \
#       --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
#
# The app-specific password comes from appleid.apple.com, not your Apple ID
# password. Override the profile name with NOTARY_PROFILE.
set -euo pipefail
cd "$(dirname "$0")/.."

TARGET="${1:-}"
PROFILE="${NOTARY_PROFILE:-Clipvelope}"

if [ -z "$TARGET" ] || [ ! -e "$TARGET" ]; then
    echo "usage: $0 <path to .app or .dmg>" >&2
    exit 2
fi

# Preflight, so the failure is explained here rather than by a submission that
# is rejected minutes later. Every check runs, so one command reports every
# problem instead of one per attempt.
#
# The signature is read once into a variable rather than piped into grep -q:
# under `set -o pipefail`, grep -q exits on the first match, codesign takes
# SIGPIPE, and the pipeline reports failure precisely when the match succeeded.
fail=0
info=$(codesign -dv --verbose=4 "$TARGET" 2>&1 || true)

if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    echo "error: no notarytool credentials under the profile '$PROFILE'." >&2
    echo "       Create them with:" >&2
    echo "         xcrun notarytool store-credentials $PROFILE \\" >&2
    echo "             --apple-id <id> --team-id <team> --password <app-specific-password>" >&2
    fail=1
fi

authority=$(printf '%s\n' "$info" | sed -n 's/^Authority=//p' | head -1)
if [ -z "$authority" ]; then
    echo "error: $TARGET is not signed. Notarization requires a signature." >&2
    fail=1
elif [ "${authority#Developer ID}" = "$authority" ]; then
    echo "error: signed by '$authority'." >&2
    echo "       Apple notarizes Developer ID signatures only. An Apple Development" >&2
    echo "       certificate is for running on your own machines; see docs/DISTRIBUTION.md." >&2
    fail=1
fi

case "$TARGET" in
    *.app|*.app/)
        case "$info" in
            *"flags="*"runtime"*) ;;
            *)
                echo "error: $TARGET was not signed with the hardened runtime." >&2
                fail=1
                ;;
        esac
        ;;
esac

case "$info" in
    *"Timestamp="*) ;;
    *)
        echo "error: $TARGET has no secure timestamp; notarization rejects that." >&2
        fail=1
        ;;
esac

[ "$fail" = 0 ] || exit 1

# Every Mach-O in the bundle must carry a Developer ID signature with a secure
# timestamp, not just the outer app: Apple checks each one, and the first
# submission of this project failed on a helper binary three levels down.
app_for_scan="$TARGET"
if [ "${TARGET##*.}" = dmg ]; then
    scan_mount=$(hdiutil attach -nobrowse -readonly "$TARGET" | grep -oE '/Volumes/.*$' | tail -1)
    app_for_scan=$(ls -d "$scan_mount"/*.app | head -1)
fi
bad=0
while IFS= read -r bin; do
    file -b "$bin" | grep -q 'Mach-O' || continue
    info=$(codesign -dvv "$bin" 2>&1)
    if ! grep -q 'Authority=Developer ID Application' <<<"$info"; then
        echo "not Developer ID signed: ${bin#"$app_for_scan"/}" >&2; bad=1
    elif ! grep -q '^Timestamp=' <<<"$info"; then
        echo "no secure timestamp:    ${bin#"$app_for_scan"/}" >&2; bad=1
    fi
done < <(find "$app_for_scan" -type f -perm +111)
[ -n "${scan_mount:-}" ] && hdiutil detach "$scan_mount" -quiet
if [ "$bad" != 0 ]; then
    echo "error: fix the signatures above before submitting; Apple would reject the upload" >&2
    exit 1
fi

echo "submitting $TARGET ..."
submission=$(xcrun notarytool submit "$TARGET" --keychain-profile "$PROFILE" --wait 2>&1 | tee /dev/stderr)
status=$(printf '%s\n' "$submission" | awk '/^ *status:/ {s=$2} END {print s}')
if [ "$status" != "Accepted" ]; then
    id=$(printf '%s\n' "$submission" | awk '/^ *id:/ {print $2; exit}')
    echo >&2
    echo "error: notarization status is '${status:-unknown}', not Accepted. Apple's log:" >&2
    [ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$PROFILE" >&2
    exit 1
fi

echo "stapling ..."
xcrun stapler staple "$TARGET"
xcrun stapler validate "$TARGET"

# The real question is not whether Apple accepted it, but whether a Mac that has
# never seen this app will open it.
echo "Gatekeeper assessment:"
if [ "${TARGET##*.}" = dmg ]; then
    spctl -a -vvv -t install "$TARGET" 2>&1 | sed 's/^/  /'
else
    spctl -a -vvv -t exec "$TARGET" 2>&1 | sed 's/^/  /'
fi

echo
echo "notarized and stapled: $TARGET"
