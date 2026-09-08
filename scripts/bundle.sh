#!/bin/bash
# Assembles dist/Clipvelope.app from the SwiftPM binary.
#
# SwiftPM produces a bare Mach-O executable. Clipvelope needs a real bundle:
# SMAppService.mainApp (Launch at Login) requires one, and LSUIElement -- which
# keeps a menu-bar app out of the Dock -- only exists in an Info.plist.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP="dist/Clipvelope.app"

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Clipvelope"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Clipvelope"

# Sparkle, only when the binary actually links against it. SwiftPM links but
# knows nothing about app bundles, so the framework has to be copied in and the
# executable's runpath pointed at it.
#
# Asking the binary rather than an environment variable means the bundle can
# never disagree with what was built: an app that links Sparkle and does not
# ship it dies at launch.
if otool -L "$APP/Contents/MacOS/Clipvelope" 2>/dev/null | grep -q Sparkle; then
    SPARKLE=$(find .build/artifacts -type d -name 'Sparkle.framework' 2>/dev/null | head -1)
    if [ -z "$SPARKLE" ]; then
        echo "error: the binary links Sparkle but Sparkle.framework was not found." >&2
        echo "       Build it first: CLIPVELOPE_SPARKLE=1 swift build" >&2
        exit 1
    fi
    mkdir -p "$APP/Contents/Frameworks"
    cp -R "$SPARKLE" "$APP/Contents/Frameworks/"
    # Sparkle's license requires its notice to travel with the software.
    cp docs/THIRD-PARTY-LICENSES.md "$APP/Contents/Resources/THIRD-PARTY-LICENSES.md"
    install_name_tool -add_rpath "@executable_path/../Frameworks" \
        "$APP/Contents/MacOS/Clipvelope" 2>/dev/null || true
    echo "embedded $(basename "$SPARKLE")"
fi
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Signing identity.
#
# Ad-hoc (the default) is fine for running Clipvelope on the machine that built
# it. Verified on macOS 26: the Keychain key stays readable across rebuilds and
# Launch at Login registers successfully. A real identity matters when the app
# leaves this machine, and for notarization, the hardened runtime and
# entitlements. See docs/SIGNING.md.
#
# If exactly one code-signing identity is available it is used automatically.
if [ -z "${CODESIGN_IDENTITY:-}" ]; then
    identities=$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/^ *[0-9]*) [0-9A-F]* "\(.*\)"$/\1/p')
    count=$(printf '%s' "$identities" | grep -c . || true)
    if [ "$count" = "1" ]; then
        CODESIGN_IDENTITY="$identities"
        echo "using the only available signing identity: $CODESIGN_IDENTITY"
    else
        CODESIGN_IDENTITY="-"
        [ "$count" = "0" ] || echo "note: $count identities available; set CODESIGN_IDENTITY to pick one"
    fi
fi

# The keychain-access-groups entitlement is what would put the vault key in the
# data protection keychain, where other apps cannot read it. It is a *restricted*
# entitlement: the kernel kills any process carrying it that is not authorised by
# an embedded provisioning profile. A signing identity alone is not enough --
# verified with an Apple Development certificate, exit 137 -- so it is applied
# only when a profile is actually present. See docs/SIGNING.md.
PROFILE="${PROVISIONING_PROFILE:-Resources/embedded.provisionprofile}"
ENTITLED=no

# Nested code is signed innermost first: signing the outer bundle seals a hash
# of everything inside it, so anything re-signed afterwards invalidates it.
sign_nested() {
    local identity="$1" timestamp="$2"
    local fw="$APP/Contents/Frameworks/Sparkle.framework"
    [ -d "$fw" ] || return 0

    local inner
    while IFS= read -r inner; do
        [ -e "$inner" ] || continue
        codesign --force --sign "$identity" --options runtime "$timestamp" "$inner"
    done < <(find "$fw" -name '*.xpc' -o -name '*.app' -maxdepth 4 2>/dev/null)

    # Autoupdate is a bare executable next to the bundles, not inside one, so the
    # loop above never reaches it. Left alone it keeps Sparkle's own signature --
    # no Developer ID, no timestamp -- and notarization rejects the whole image.
    local tool
    for tool in "$fw"/Versions/*/Autoupdate; do
        [ -f "$tool" ] || continue
        codesign --force --sign "$identity" --options runtime "$timestamp" "$tool"
    done

    codesign --force --sign "$identity" --options runtime "$timestamp" "$fw"
}

# Notarization refuses a signature without a secure timestamp, and a timestamp
# needs Apple's server, so it is used only where it can matter: a real identity.
# Ad-hoc builds skip it, which keeps CI and offline builds working.
if [ "$CODESIGN_IDENTITY" = "-" ]; then
    TIMESTAMP=--timestamp=none
else
    TIMESTAMP=--timestamp
fi

if [ "$CODESIGN_IDENTITY" != "-" ] && [ -f "$PROFILE" ]; then
    # A keychain access group must carry the team identifier, which lives in the
    # OU of the signing certificate.
    common_name="${CODESIGN_IDENTITY}"
    team=$(security find-certificate -c "$common_name" -p 2>/dev/null \
           | openssl x509 -noout -subject 2>/dev/null \
           | tr '/' '\n' | sed -n 's/^OU=//p' | head -1)
    if [ -z "$team" ]; then
        echo "error: could not read the team identifier from $common_name" >&2
        exit 1
    fi
    sign_nested "$CODESIGN_IDENTITY" "$TIMESTAMP"
    cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
    # Kept outside the bundle: codesign seals everything under Contents/, and a
    # stray file there is "an unsigned subcomponent" that fails the signature.
    ENTITLEMENTS=$(mktemp -t clipvelope-entitlements)
    sed "s/\$(AppIdentifierPrefix)/$team./" Resources/Clipvelope.entitlements > "$ENTITLEMENTS"
    codesign --force --sign "$CODESIGN_IDENTITY" --identifier com.mujieha.Clipvelope \
             --entitlements "$ENTITLEMENTS" \
             --options runtime "$TIMESTAMP" "$APP"
    rm -f "$ENTITLEMENTS"
    ENTITLED=yes
    echo "signed with $CODESIGN_IDENTITY, keychain access group $team.com.mujieha.Clipvelope"
elif [ "$CODESIGN_IDENTITY" != "-" ]; then
    sign_nested "$CODESIGN_IDENTITY" "$TIMESTAMP"
    codesign --force --sign "$CODESIGN_IDENTITY" --identifier com.mujieha.Clipvelope \
             --options runtime "$TIMESTAMP" "$APP"
    echo "signed with $CODESIGN_IDENTITY"
else
    sign_nested - "$TIMESTAMP"
    codesign --force --sign - --identifier com.mujieha.Clipvelope \
             --options runtime "$TIMESTAMP" "$APP"
fi

# Launch it. A restricted entitlement, a broken signature or a bad Info.plist all
# produce an app that dies immediately, and every one of those is invisible until
# something tries to run it. --status exits without starting the UI.
if ! "$APP/Contents/MacOS/Clipvelope" --status >/dev/null 2>&1; then
    launch_status=$?
    echo >&2
    echo "error: the signed app will not launch (exit $launch_status)." >&2
    if [ -d "$APP/Contents/Frameworks/Sparkle.framework" ] \
       && [ "$CODESIGN_IDENTITY" = "-" ]; then
        echo "       An embedded framework needs the app and the framework to share" >&2
        echo "       an Apple team identifier, and an ad-hoc signature has none." >&2
        echo "       Build without the updater, or sign with a real identity." >&2
    fi
    if [ "$ENTITLED" = yes ]; then
        echo "       The provisioning profile at $PROFILE probably does not" >&2
        echo "       authorise the keychain-access-groups entitlement." >&2
    fi
    exit 1
fi

if [ "$ENTITLED" = no ]; then
    echo
    echo "note: no provisioning profile, so the vault key stays in the file"
    echo "      keychain where any app running as you can read it."
    echo "      See docs/SIGNING.md for what a profile requires."
fi
echo
echo "built $APP"
