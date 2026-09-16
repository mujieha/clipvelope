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
#
# It exits 2, and says why on stderr, when the window list cannot be read at
# all. CGWindowListCopyWindowInfo returns nil in a session with no window server
# -- a fast-user-switched background session, for one -- and the force-cast this
# used to do trapped there, printing "Trace/BPT trap: 5" into the middle of the
# diagnostics that were supposed to explain a failure. That is the worst moment
# to crash, and "could not look" is not the same answer as "the panel is closed".
cat > "$TMP/windows.swift" <<'EOF'
import CoreGraphics
import Foundation

guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
    FileHandle.standardError.write(Data(
        "cannot read the window list: this session has no window server\n".utf8))
    exit(2)
}
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

# Waits for the copy that was running to be gone before starting another one.
# The app is single-instance within a login session -- see SingleInstance -- so
# a launch that overlaps the old process quitting hands over to it and exits,
# and the test then reports an app that "did not start" when what really
# happened is that it declined to be the second copy. The extra second is for
# Launch Services, whose list of running applications lags the process table.
wait_for_exit() {
    for _ in $(seq 1 20); do
        pgrep -f "$BIN" >/dev/null || break
        sleep 0.5
    done
    sleep 1
}

was_running=0
if pgrep -f "$BIN" >/dev/null; then was_running=1; fi
pkill -f "$BIN" 2>/dev/null || true
wait_for_exit

# Exit 1 means the app ran and a window that should have appeared did not.
# Exit 2 means the test could not be run at all, which is a different answer and
# has to read as one.
NO_WINDOW_SERVER=2

fail() {
    echo "smoke: FAIL: $1" >&2
    echo "Clipvelope windows, on screen or not:" >&2
    "$TMP/windows" >&2 || true
    pkill -f "$BIN" 2>/dev/null || true
    exit 1
}

# Refreshes $TMP/report with what the window lister can see, and abandons the
# run -- with its own wording and its own exit status -- when the window list
# cannot be read at all.
#
# Callers grep the file afterwards instead of piping the lister into grep. A
# pipeline would run this in a subshell, where the exit below would end the
# subshell and leave the script walking on as though the windows had merely
# been closed; and pipefail or not, grep's status is what an `if` would see.
refresh_windows() {
    local status=0
    "$TMP/windows" > "$TMP/report" 2> "$TMP/report.err" || status=$?
    if [ "$status" -eq "$NO_WINDOW_SERVER" ]; then
        echo "smoke: CANNOT RUN: $(cat "$TMP/report.err")" >&2
        echo "smoke: nothing could be looked at, so this says nothing about whether the panel opens." >&2
        pkill -f "$BIN" 2>/dev/null || true
        exit "$NO_WINDOW_SERVER"
    fi
    if [ "$status" -ne 0 ]; then
        cat "$TMP/report.err" >&2
        fail "the window lister exited $status"
    fi
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
    refresh_windows
    if grep -q '^history-panel: open$' "$TMP/report"; then opened=1; break; fi
done
[ "$opened" = 1 ] || fail "the history panel did not open within 45s"
echo "smoke: history panel opened"

"$BIN" --preferences
for _ in $(seq 1 10); do
    sleep 1
    refresh_windows
    if grep -q '^preferences: open$' "$TMP/report"; then break; fi
done
grep -q '^preferences: open$' "$TMP/report" || fail "Preferences did not open within 10s"
echo "smoke: Preferences opened"

pkill -f "$BIN" 2>/dev/null || true
if [ "$was_running" = 1 ]; then
    wait_for_exit
    open "$APP"
    echo "smoke: relaunched the instance that was running before"
fi
echo "smoke: OK"
