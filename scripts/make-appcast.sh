#!/bin/bash
# Generates dist/appcast.xml from the disk images in dist/.
#
# Sparkle's generate_appcast signs every update with the EdDSA private key held
# in the login keychain, and writes the signature into the feed. A client
# refuses anything whose signature does not match the SUPublicEDKey compiled
# into the app, so an attacker who replaces the download still cannot ship code.
set -euo pipefail
cd "$(dirname "$0")/.."

TOOL=$(find .build/artifacts -type f -name generate_appcast 2>/dev/null | head -1)
if [ -z "$TOOL" ]; then
    echo "error: generate_appcast not found." >&2
    echo "       It ships with Sparkle: CLIPVELOPE_SPARKLE=1 swift build" >&2
    exit 1
fi

if ! ls dist/*.dmg >/dev/null 2>&1; then
    echo "error: no disk images in dist/. Run 'make dmg' first." >&2
    exit 1
fi

# The first run asks the keychain for the EdDSA private key and macOS puts up a
# prompt. Choose "Always Allow" and it will not ask again; a CI machine needs the
# key exported and imported deliberately instead.
#
# generate_appcast reads every update in the folder, not just the newest, so the
# feed keeps its history and Sparkle can offer the right one to an old install.
# Release notes: the CHANGELOG.md section for each version, as a small HTML
# fragment next to its disk image. generate_appcast embeds a fragment with no
# <body> into the feed item, and Sparkle shows it in the update prompt.
for dmg in dist/*.dmg; do
    ver=$(basename "$dmg" .dmg | sed 's/^Clipvelope-//')
    notes="dist/Clipvelope-$ver.html"
    python3 - "$ver" > "$notes" <<'EOF'
import sys, re, html
ver = sys.argv[1]
text = open("CHANGELOG.md").read()
m = re.search(r"^## " + re.escape(ver) + r"\s*\n(.*?)(?=^## |\Z)", text, re.S | re.M)
if not m:
    sys.exit(f"CHANGELOG.md has no section for {ver}")
out, items = [], []
def flush():
    global items
    if items:
        out.append("<ul>" + "".join(f"<li>{i}</li>" for i in items) + "</ul>")
        items = []
for para in re.split(r"\n\s*\n", m.group(1).strip()):
    lines = [l.strip() for l in para.splitlines()]
    if all(l.startswith("- ") or not l.startswith("-") and i > 0 for i, l in enumerate(lines)) and lines[0].startswith("- "):
        cur = []
        for l in lines:
            if l.startswith("- "):
                if cur: items.append(html.escape(" ".join(cur)))
                cur = [l[2:]]
            else:
                cur.append(l)
        if cur: items.append(html.escape(" ".join(cur)))
        flush()
    else:
        flush()
        out.append("<p>" + html.escape(" ".join(lines)) + "</p>")
flush()
print("\n".join(out))
EOF
    echo "release notes for $ver -> $notes"
done

echo "signing updates (macOS may ask for keychain access to the Sparkle key) ..."
"$TOOL" --embed-release-notes dist/

if [ ! -f dist/appcast.xml ]; then
    echo "error: no appcast.xml was produced" >&2
    exit 1
fi

echo
echo "wrote dist/appcast.xml"
echo "Publish it at the SUFeedURL in Resources/Info.plist:"
/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' Resources/Info.plist
