#!/bin/bash
# Launches the built app and checks that the two things a user can open
# actually open: the history panel and Preferences. The unit tests cannot reach
# either -- SwiftUI windows do not exist in a headless test -- and this project
# has shipped a Preferences window that silently did not appear.
#
# Uses the app's own --open and --preferences entry points, so it needs no
# Accessibility permission. Restarts an instance that was already running.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="$PWD/dist/Clipvelope.app"
BIN="$APP/Contents/MacOS/Clipvelope"
if [ ! -x "$BIN" ]; then
    echo "error: $APP is not built. Run 'make app' first." >&2
    exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Lists Clipvelope's on-screen windows with their layer: 101 is the menu bar
# panel, 0 is an ordinary window such as Preferences.
cat > "$TMP/windows.swift" <<'EOF'
import CoreGraphics
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
for w in list where (w["kCGWindowOwnerName"] as? String) == "Clipvelope" {
    print("layer=\(w["kCGWindowLayer"] ?? -1) title=\(w["kCGWindowName"] ?? "")")
}
EOF
swiftc -O -o "$TMP/windows" "$TMP/windows.swift"

was_running=0
if pgrep -f "$BIN" >/dev/null; then was_running=1; fi
pkill -f "$BIN" 2>/dev/null || true
sleep 1

fail() {
    echo "smoke: FAIL: $1" >&2
    echo "on-screen Clipvelope windows:" >&2
    "$TMP/windows" >&2 || true
    pkill -f "$BIN" 2>/dev/null || true
    exit 1
}

open "$APP"
for _ in $(seq 1 40); do
    pgrep -f "$BIN" >/dev/null && break
    sleep 0.5
done
pgrep -f "$BIN" >/dev/null || fail "the app did not start"

# A freshly signed binary takes several seconds to validate on first launch, and
# a request that arrives before the app listens is lost. --open only opens the
# panel if it is not already open, so asking repeatedly is safe.
opened=0
for _ in $(seq 1 15); do
    sleep 2
    "$BIN" --open >/dev/null 2>&1 || true
    sleep 1
    if "$TMP/windows" | grep -q 'layer=101'; then opened=1; break; fi
done
[ "$opened" = 1 ] || fail "the history panel did not open within 45s"
echo "smoke: history panel opened"

"$BIN" --preferences
for _ in $(seq 1 10); do
    sleep 1
    if "$TMP/windows" | grep -q 'layer=0 '; then break; fi
done
"$TMP/windows" | grep -q 'layer=0 ' || fail "Preferences did not open within 10s"
echo "smoke: Preferences opened"

pkill -f "$BIN" 2>/dev/null || true
if [ "$was_running" = 1 ]; then
    sleep 1
    open "$APP"
    echo "smoke: relaunched the instance that was running before"
fi
echo "smoke: OK"
