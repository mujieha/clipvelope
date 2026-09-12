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

. "$(dirname "$0")/select-xcode.sh"

exec swift test "$@"
