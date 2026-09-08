#!/bin/bash
# Syntax-checks every inline `run:` block in the workflows.
#
# A workflow's shell only runs on a runner, so a typo like an unmatched quote is
# invisible until a push fails - which is exactly how this was added. `bash -n`
# parses without executing and catches it locally in milliseconds.
set -euo pipefail
cd "$(dirname "$0")/.."

# Accepts explicit paths so the checker itself can be tested against a file
# known to be broken.
if [ "$#" -gt 0 ]; then
    targets=("$@")
else
    targets=(.github/workflows/*.yml)
fi

status=0
for wf in "${targets[@]}"; do
    python3 - "$wf" <<'PY' || status=1
import subprocess, sys

path = sys.argv[1]
lines = open(path).read().split("\n")
blocks, current, indent = [], None, 0

for i, line in enumerate(lines, 1):
    stripped = line.strip()
    if current is None:
        if stripped in ("run: |", "run: |-"):
            indent = len(line) - len(line.lstrip())
            current, start = [], i
        continue
    if line.strip() == "":
        current.append("")
        continue
    if (len(line) - len(line.lstrip())) <= indent:
        blocks.append((start, "\n".join(current)))
        current = None
        if stripped in ("run: |", "run: |-"):
            indent = len(line) - len(line.lstrip())
            current, start = [], i
        continue
    current.append(line[indent + 2:])

if current is not None:
    blocks.append((start, "\n".join(current)))

failed = False
for start, body in blocks:
    check = subprocess.run(["bash", "-n"], input=body, text=True,
                           capture_output=True)
    if check.returncode != 0:
        failed = True
        print(f"{path}:{start}: shell syntax error in run block")
        print(check.stderr.strip())

print(f"{path}: checked {len(blocks)} run block(s)")
sys.exit(1 if failed else 0)
PY
done
exit $status
