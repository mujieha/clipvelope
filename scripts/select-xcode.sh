#!/bin/bash
# Sourced, not run: points DEVELOPER_DIR at a full Xcode when the active
# developer directory is the Command Line Tools.
#
# Two different things in this repo need Xcode rather than the CLT, and both used
# to discover it separately or not at all:
#
#   - XCTest ships inside Xcode, so `swift test` under the CLT fails with
#     "no such module 'XCTest'".
#   - The SwiftUI macro plugins ship inside Xcode too, so `swift build` under the
#     CLT fails in Views.swift with "External macro implementation type
#     'SwiftUIMacros.StateMacro' could not be found".
#
# scripts/test.sh handled the first and scripts/bundle.sh handled neither, so on
# a machine whose xcode-select points at the CLT -- the default after installing
# the CLT alone -- `make test` worked and `make app` did not, even though the
# project's own documentation says the make targets are the only supported entry
# points. CI never saw it because a GitHub runner already selects Xcode.
#
# DEVELOPER_DIR is exported for the current command only. Changing xcode-select
# globally needs sudo and affects everything else on the machine.

# A full Xcode has the macOS platform's developer frameworks; the CLT does not.
# XCTest.framework is the cheapest thing to look for that is present in one and
# absent in the other.
_clipvelope_is_xcode() {
    [ -d "$1/Platforms/MacOSX.platform/Developer/Library/Frameworks/XCTest.framework" ]
}

# Honour an explicit DEVELOPER_DIR: someone who set it means it.
if [ -z "${DEVELOPER_DIR:-}" ] && ! _clipvelope_is_xcode "$(xcode-select -p)"; then
    for _clipvelope_candidate in /Applications/Xcode.app /Applications/Xcode_*.app /Applications/Xcode*.app; do
        [ -d "$_clipvelope_candidate" ] || continue
        if _clipvelope_is_xcode "$_clipvelope_candidate/Contents/Developer"; then
            export DEVELOPER_DIR="$_clipvelope_candidate/Contents/Developer"
            echo "using $DEVELOPER_DIR (the active developer directory is the Command Line Tools)"
            break
        fi
    done
    unset _clipvelope_candidate
fi

if [ -z "${DEVELOPER_DIR:-}" ] && ! _clipvelope_is_xcode "$(xcode-select -p)"; then
    echo "error: no Xcode found, and the Command Line Tools cannot build this project." >&2
    echo "       Install Xcode, or set DEVELOPER_DIR to one." >&2
    exit 1
fi
