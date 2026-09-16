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

# SwiftPM has two build layouts and this project meets both. The classic one
# puts the bundle at .build/<triple>/debug/ClipvelopePackageTests.xctest; the
# newer Swift Build backend puts it at .build/out/Products/Debug, and names it
# after the test target instead. A machine that has used both keeps artifacts
# from each, so picking whichever `find` happens to return first can report
# coverage for a build several commits old -- and hard-coding the classic name
# fails outright on a machine that has only ever used the new layout, which is
# how this was found: 253 tests passed on the macOS 27 runner and the gate said
# there was no coverage data at all.
#
# So: take the most recently written profile, and prefer the bundle sitting
# beside it, which is the one that profile describes.
prof=$(find .build -name default.profdata -type f 2>/dev/null | while read -r p; do
    printf '%s\t%s\n' "$(stat -f %m "$p")" "$p"
done | sort -rn | head -1 | cut -f2-)

if [ -z "$prof" ]; then
    echo "error: no coverage data. Run ./scripts/test.sh --enable-code-coverage first." >&2
    exit 1
fi

products=$(dirname "$(dirname "$prof")")
bundle=$(find "$products" -maxdepth 1 -name '*.xctest' 2>/dev/null | head -1)
if [ -z "$bundle" ]; then
    bundle=$(find .build -name '*.xctest' 2>/dev/null | head -1)
fi
bin="$bundle/Contents/MacOS/$(basename "$bundle" .xctest)"

if [ -z "$bundle" ] || [ ! -f "$bin" ]; then
    echo "error: found a coverage profile at $prof but no test bundle to read it against." >&2
    echo "       Run ./scripts/test.sh --enable-code-coverage first." >&2
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
