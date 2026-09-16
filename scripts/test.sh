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

# Relative to the repo root, not to $0: the cd above has already moved us there,
# and re-resolving $0's dirname afterwards breaks when the script is invoked from
# inside scripts/ (dirname is ".", so this would look for ./select-xcode.sh in
# the root).
. ./scripts/select-xcode.sh

exec swift test "$@"
