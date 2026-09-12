#!/bin/bash
# Generates dist/appcast.xml from the disk images in dist/.
#
# Sparkle's generate_appcast signs every update with the EdDSA private key held
# in the login keychain, and writes the signature into the feed. A client
# refuses anything whose signature does not match the SUPublicEDKey compiled
# into the app, so an attacker who replaces the download still cannot ship code.
set -euo pipefail
cd "$(dirname "$0")/.."

# Sparkle needs an absolute URL for the download, or it has nothing to fetch.
# GitHub serves a release asset at <repo>/releases/download/<tag>/<file>, and the
# tag for a release is v<version>, so the base is derived from the feed URL
# rather than written down twice.
#
# generate_appcast takes one --download-url-prefix and applies it to everything
# it writes, but the feed carries an item per disk image in dist/ and each of
# those images lives under its own tag. A single prefix therefore advertises
# 0.1.0 at .../v0.2.0/Clipvelope-0.1.0.dmg as soon as a second release exists,
# which is a 404 for exactly the users who need the update. The prefix is only
# the starting point: each URL is rewritten from its own filename afterwards.
#
# CLIPVELOPE_DOWNLOAD_PREFIX overrides all of that, for downloads hosted
# somewhere other than GitHub releases. It applies to every item unchanged; that
# is the escape hatch, not the bug above.
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
feed=$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' Resources/Info.plist)
repo=${feed%/releases/*}
BASE="$repo/releases/download"
OVERRIDE="${CLIPVELOPE_DOWNLOAD_PREFIX:-}"
PREFIX="${OVERRIDE:-$BASE/v$version/}"

# One place decides what URL a file is advertised at, and both the rewrite and
# the self-test go through it: a rule that is right in the self-test and wrong in
# the feed would be worse than no self-test at all.
#
#   appcast_urls selftest        - print the URLs two made-up images would get
#   appcast_urls rewrite <feed>  - rewrite every enclosure URL in that feed
appcast_urls() {
    python3 - "$1" "$BASE" "$OVERRIDE" "${2:-}" <<'EOF'
import re, sys

mode, base, override, path = sys.argv[1:5]

# Disk images are named by make-dmg.sh: Clipvelope-<version>.dmg. Delta updates
# are named by generate_appcast and carry build numbers instead of a version.
IMAGE = re.compile(r"^Clipvelope-([0-9]+(?:\.[0-9]+)*(?:[-+][0-9A-Za-z.]+)?)\.dmg$")


def url(name):
    """Where one disk image is advertised, decided by its own filename."""
    if override:
        return override + name
    match = IMAGE.match(name)
    if not match:
        sys.exit(f"error: cannot read a version from {name}.\n"
                 "       Disk images must be named Clipvelope-<version>.dmg, or\n"
                 "       the feed would point at a tag that does not exist.")
    return f"{base}/v{match.group(1)}/{name}"


if mode == "selftest":
    for name in ("Clipvelope-0.1.0.dmg", "Clipvelope-0.2.0.dmg"):
        print(f"  {name} -> {url(name)}")
    sys.exit(0)

feed = open(path).read()

# A feed can itself be signed, over its own bytes, when an update's Info.plist
# asks for it with SURequireSignedFeed. Nothing here does, and rewriting a signed
# feed would produce one that every client rejects, so stop rather than ship it.
if "sparkle-signatures:" in feed or "sparkle-sign-warning:" in feed:
    sys.exit("error: this appcast is signed as a whole, and rewriting it would\n"
             "       invalidate that signature. Teach this step to re-sign the\n"
             "       feed before enabling SURequireSignedFeed.")

images = 0


def fix(match):
    """Rewrite one enclosure URL, leaving every other byte of the feed alone."""
    global images
    name = match.group(2).rsplit("/", 1)[-1]
    if name.endswith(".delta"):
        # A delta only ever belongs to the newest item, which is the version the
        # prefix was built from, so generate_appcast already placed it right.
        print(f"  {match.group(2)} (delta, already under the newest tag)")
        return match.group(0)
    images += 1
    fixed = url(name)
    print(f"  {fixed}")
    return match.group(1) + fixed + match.group(3)


# Rewriting the attribute in place beats reparsing and reserialising: the
# signature next to it covers the disk image's bytes, not the feed's, and every
# other byte of this file is generate_appcast's business rather than ours.
out = re.sub(r'(<enclosure\b[^>]*?\burl=")([^"]+)(")', fix, feed)

if images == 0:
    sys.exit("error: the appcast advertises no disk image to rewrite a URL for")

open(path, "w").write(out)
EOF
}

# Proves the URL rule with no signing key, no Sparkle build and no disk image:
# it asks what two made-up releases would be advertised at, and then rewrites a
# feed shaped like the one generate_appcast writes and checks each item came out
# under its own tag. The second half is the one that matters -- the rule being
# right is no use if the rewrite does not find the attribute it applies to.
if [ "${CLIPVELOPE_APPCAST_SELFTEST:-0}" = 1 ]; then
    echo "self-test: the URL each disk image would be advertised at"
    appcast_urls selftest

    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    cat > "$tmp/appcast.xml" <<'FEED'
<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
<channel>
<title>Clipvelope</title>
<item>
<title>0.2.0</title>
<sparkle:version>2</sparkle:version>
<sparkle:shortVersionString>0.2.0</sparkle:shortVersionString>
<enclosure url="https://example.invalid/releases/download/v0.2.0/Clipvelope-0.2.0.dmg" length="1" type="application/octet-stream" sparkle:edSignature="AAAA"/>
</item>
<item>
<title>0.1.0</title>
<sparkle:version>1</sparkle:version>
<sparkle:shortVersionString>0.1.0</sparkle:shortVersionString>
<enclosure url="https://example.invalid/releases/download/v0.2.0/Clipvelope-0.1.0.dmg" length="1" type="application/octet-stream" sparkle:edSignature="BBBB"/>
</item>
</channel>
</rss>
FEED

    echo
    echo "self-test: rewriting a feed where both items sit under the newest tag"
    appcast_urls rewrite "$tmp/appcast.xml"

    fail=0
    grep -q 'url="[^"]*/v0\.1\.0/Clipvelope-0\.1\.0\.dmg"' "$tmp/appcast.xml" \
        || { echo "self-test FAILED: 0.1.0 is not advertised under v0.1.0" >&2; fail=1; }
    grep -q 'url="[^"]*/v0\.2\.0/Clipvelope-0\.2\.0\.dmg"' "$tmp/appcast.xml" \
        || { echo "self-test FAILED: 0.2.0 is not advertised under v0.2.0" >&2; fail=1; }
    # The signature sits beside the URL and covers the disk image, not the feed.
    # Rewriting must leave it byte for byte, or every client refuses the update.
    grep -q 'sparkle:edSignature="AAAA"' "$tmp/appcast.xml" \
        || { echo "self-test FAILED: an edSignature was disturbed" >&2; fail=1; }
    grep -q 'sparkle:edSignature="BBBB"' "$tmp/appcast.xml" \
        || { echo "self-test FAILED: an edSignature was disturbed" >&2; fail=1; }

    echo
    if [ "$fail" = 0 ]; then
        echo "self-test passed"
    else
        echo "self-test FAILED" >&2
    fi
    exit "$fail"
fi

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
    # Refuse an image whose version cannot be read, here, before anything is
    # signed: a feed with one wrong URL looks exactly like a correct one.
    if ! printf '%s' "$ver" | grep -Eq '^[0-9]+(\.[0-9]+)*([-+][0-9A-Za-z.]+)?$'; then
        echo "error: cannot read a version from $dmg" >&2
        echo "       disk images must be named Clipvelope-<version>.dmg" >&2
        exit 1
    fi
    notes="dist/Clipvelope-$ver.html"
    python3 - "$ver" > "$notes" <<'EOF'
import sys, re, html
ver = sys.argv[1]
text = open("CHANGELOG.md").read()
m = re.search(r"^## " + re.escape(ver) + r"\s*\n(.*?)(?=^## |\Z)", text, re.S | re.M)
if not m:
    sys.exit(f"CHANGELOG.md has no section for {ver}")

def inline(s):
    """Escape, then render `code` spans. Escaping first keeps the markup safe."""
    return re.sub(r"`([^`]+)`", r"<code>\1</code>", html.escape(s))

out, items = [], []
def flush():
    global items
    if items:
        out.append("<ul>" + "".join(f"<li>{i}</li>" for i in items) + "</ul>")
        items = []

for para in re.split(r"\n\s*\n", m.group(1).strip()):
    lines = [l.strip() for l in para.splitlines()]
    if lines[0].startswith("#"):
        # A heading is its own paragraph; depth maps to h3/h4 so the update
        # prompt shows structure rather than literal hashes.
        flush()
        level = len(lines[0]) - len(lines[0].lstrip("#"))
        tag = "h3" if level <= 3 else "h4"
        out.append(f"<{tag}>{inline(lines[0].lstrip('#').strip())}</{tag}>")
        continue
    if lines[0].startswith("- "):
        cur = []
        for l in lines:
            if l.startswith("- "):
                if cur: items.append(inline(" ".join(cur)))
                cur = [l[2:]]
            else:
                cur.append(l)
        if cur: items.append(inline(" ".join(cur)))
        flush()
    else:
        flush()
        out.append("<p>" + inline(" ".join(lines)) + "</p>")
flush()
print("\n".join(out))
EOF
    echo "release notes for $ver -> $notes"
done

echo "signing updates (macOS may ask for keychain access to the Sparkle key) ..."
echo "downloads will be advertised under $PREFIX to begin with"
"$TOOL" --embed-release-notes --download-url-prefix "$PREFIX" dist/

if [ ! -f dist/appcast.xml ]; then
    echo "error: no appcast.xml was produced" >&2
    exit 1
fi

# Now give every item back its own tag. Skipped when the prefix was overridden:
# there the operator has said where the downloads live, and it is one place.
if [ -z "$OVERRIDE" ]; then
    echo
    echo "advertising each disk image under its own release tag:"
    appcast_urls rewrite dist/appcast.xml
fi

echo
echo "wrote dist/appcast.xml"
echo "Publish it at the SUFeedURL in Resources/Info.plist:"
/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' Resources/Info.plist
