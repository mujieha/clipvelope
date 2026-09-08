#!/bin/bash
# Runs the test suite.
#
# XCTest ships inside Xcode, not the Command Line Tools. If the active developer
# directory is the Command Line Tools, `swift test` fails with "no such module
# 'XCTest'". Point DEVELOPER_DIR at Xcode for this one command rather than
# changing xcode-select globally, which needs sudo and affects everything else
# on the machine.
set -euo pipefail
cd "$(dirname "$0")/.."

has_xctest() {
    [ -d "$1/Platforms/MacOSX.platform/Developer/Library/Frameworks/XCTest.framework" ]
}

if [ -z "${DEVELOPER_DIR:-}" ] && ! has_xctest "$(xcode-select -p)"; then
    for candidate in /Applications/Xcode.app /Applications/Xcode_*.app /Applications/Xcode*.app; do
        [ -d "$candidate" ] || continue
        if has_xctest "$candidate/Contents/Developer"; then
            export DEVELOPER_DIR="$candidate/Contents/Developer"
            echo "using $DEVELOPER_DIR for XCTest"
            break
        fi
    done
fi

if [ -z "${DEVELOPER_DIR:-}" ] && ! has_xctest "$(xcode-select -p)"; then
    echo "error: no Xcode with XCTest found. Install Xcode, or set DEVELOPER_DIR." >&2
    exit 1
fi

exec swift test "$@"
