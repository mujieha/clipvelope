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

# Lists every window Clipvelope owns -- not only the ones on screen -- and then
# says whether the history panel and Preferences are actually showing.
#
# Two reasons it asks for [.optionAll] and tests kCGWindowIsOnscreen itself
# rather than letting [.optionOnScreenOnly] do the filtering.
#
# The first is that the app now keeps its history panel's NSWindow alive between
# opens, so the window exists from launch to quit and "a window is listed" no
# longer means "the panel is open". The test has to look at whether it is on
# screen, and if that is the question then asking it out loud is better than
# hoping a list option still means what it did. The same is true of Preferences:
# the Settings scene has a window in the list before it has ever been shown.
#
# The second is that "the window exists but is not on screen" is precisely the
# signature of the macOS 27 bug this detection was rewritten for -- a panel that
# was asked to open and silently did not. [.optionOnScreenOnly] cannot show that
# state at all: it returns nothing and leaves whoever is reading the failure to
# guess whether the window was missing or merely hidden. Printing every window
# with its own onscreen flag puts the answer in the failure output.
#
# Layer 101 is the panel, which sits above the menu bar; layer 0 is an ordinary
# window such as Preferences. The size floors keep a stray zero-sized or
# placeholder window from being mistaken for either: a window nobody can see is
# not an open panel, whatever the window server lists.
cat > "$TMP/windows.swift" <<'EOF'
import CoreGraphics

let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String: Any]]
let mine = list.filter { ($0["kCGWindowOwnerName"] as? String) == "Clipvelope" }

func showing(layer: Int, minWidth: CGFloat, minHeight: CGFloat) -> Bool {
    mine.contains { window in
        guard (window["kCGWindowLayer"] as? Int) == layer,
              (window["kCGWindowIsOnscreen"] as? Bool) == true,
              let bounds = window["kCGWindowBounds"] as? [String: CGFloat],
              let width = bounds["Width"], let height = bounds["Height"]
        else { return false }
        return width >= minWidth && height >= minHeight
    }
}

for window in mine {
    let bounds = window["kCGWindowBounds"] as? [String: CGFloat] ?? [:]
    let onscreen = (window["kCGWindowIsOnscreen"] as? Bool) == true
    print("layer=\(window["kCGWindowLayer"] ?? -1)",
          "onscreen=\(onscreen ? 1 : 0)",
          "size=\(Int(bounds["Width"] ?? 0))x\(Int(bounds["Height"] ?? 0))",
          "title=\(window["kCGWindowName"] ?? "")")
}

print("history-panel: \(showing(layer: 101, minWidth: 200, minHeight: 100) ? "open" : "closed")")
print("preferences: \(showing(layer: 0, minWidth: 200, minHeight: 200) ? "open" : "closed")")
EOF
swiftc -O -o "$TMP/windows" "$TMP/windows.swift"

was_running=0
if pgrep -f "$BIN" >/dev/null; then was_running=1; fi
pkill -f "$BIN" 2>/dev/null || true
sleep 1

fail() {
    echo "smoke: FAIL: $1" >&2
    echo "Clipvelope windows, on screen or not:" >&2
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
    if "$TMP/windows" | grep -q '^history-panel: open$'; then opened=1; break; fi
done
[ "$opened" = 1 ] || fail "the history panel did not open within 45s"
echo "smoke: history panel opened"

"$BIN" --preferences
for _ in $(seq 1 10); do
    sleep 1
    if "$TMP/windows" | grep -q '^preferences: open$'; then break; fi
done
"$TMP/windows" | grep -q '^preferences: open$' || fail "Preferences did not open within 10s"
echo "smoke: Preferences opened"

pkill -f "$BIN" 2>/dev/null || true
if [ "$was_running" = 1 ]; then
    sleep 1
    open "$APP"
    echo "smoke: relaunched the instance that was running before"
fi
echo "smoke: OK"
