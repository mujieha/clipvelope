#!/bin/bash
# Reports coverage and enforces a floor on the code a headless test can reach.
#
# The floor deliberately excludes Views.swift, which SwiftUI keeps at 0% however
# good the suite is, and Keychain and the pasteboard monitor, which need a real
# login keychain and a real pasteboard. A number that cannot move is not a
# signal.
#
# This lives in a script rather than inline in the workflow so that what CI runs
# and what can be run locally are the same text.
set -euo pipefail
cd "$(dirname "$0")/.."

FLOOR="${COVERAGE_FLOOR:-85}"

bin=$(find .build -name 'ClipvelopePackageTests.xctest' -maxdepth 3 | head -1)/Contents/MacOS/ClipvelopePackageTests
prof=$(find .build -name 'default.profdata' | head -1)

if [ ! -f "$bin" ] || [ -z "$prof" ]; then
    echo "error: no coverage data. Run ./scripts/test.sh --enable-code-coverage first." >&2
    exit 1
fi

echo "== whole project =="
xcrun llvm-cov report "$bin" -instr-profile "$prof" \
    -ignore-filename-regex='.*(Tests|\.build)/.*'

core=(
    Sources/Clipvelope/Models.swift
    Sources/Clipvelope/Storage.swift
    Sources/Clipvelope/BackupCodec.swift
    Sources/Clipvelope/Policies.swift
    Sources/Clipvelope/Presentation.swift
)

echo
echo "== core logic (gated) =="
xcrun llvm-cov report "$bin" -instr-profile "$prof" "${core[@]}"

lines=$(xcrun llvm-cov report "$bin" -instr-profile "$prof" "${core[@]}" \
        | awk '/^TOTAL/ { print $(NF-3) }' | tr -d '%')

if [ -z "$lines" ]; then
    echo "error: could not parse the coverage total" >&2
    exit 1
fi

awk -v got="$lines" -v floor="$FLOOR" 'BEGIN {
    if (got + 0 < floor + 0) {
        printf "core coverage %.2f%% is below the %s%% floor\n", got, floor
        exit 1
    }
    printf "core coverage %.2f%% clears the %s%% floor\n", got, floor
}'
