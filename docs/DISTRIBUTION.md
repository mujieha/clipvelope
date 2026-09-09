# Releasing Clipvelope

How a build becomes a DMG that opens on someone else's Mac without a warning
and updates itself afterwards. `docs/SIGNING.md` covers signing for local
development and why an unsigned build cannot keep its encryption key private.

## What the release scripts assume

| Requirement | Where it lives |
|---|---|
| A **Developer ID Application** certificate | the login keychain; `security find-identity -v -p codesigning` |
| Optional: a Developer ID provisioning profile for the explicit App ID `com.mujieha.Clipvelope` | `Resources/embedded.provisionprofile` (ignored by git) |
| Notarization credentials stored under the profile name `Clipvelope` | `xcrun notarytool store-credentials Clipvelope --apple-id … --team-id … --password <app-specific password>` |
| Sparkle's EdDSA signing key | the login keychain, created by Sparkle's `generate_keys`; the public half is `SUPublicEDKey` in `Resources/Info.plist` |

The provisioning profile is what moves the vault key into the data protection
keychain, where other apps cannot read it. Register the App ID with no
capabilities: every profile Apple issues already carries
`keychain-access-groups` for the team, and "Keychain Sharing" is an Xcode
switch, not a portal one. Without the profile everything still ships; the app
keeps the key in the file keychain and says so in Preferences.

**Back up the Sparkle private key** (`generate_keys -x`). Every installed copy
of the app trusts only that key; lose it and no future update can be delivered
to them.

## Commands

```bash
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" make release
make notarize TARGET=dist/Clipvelope.app          # staple the app first
make dmg                                          # image now holds a stapled app
make notarize TARGET=dist/Clipvelope-<version>.dmg
make appcast
```

`make release` builds with the updater (`CLIPVELOPE_SPARKLE=1`), signs every
executable in the bundle with the hardened runtime and a secure timestamp,
including Sparkle's `Autoupdate`, `Updater.app` and XPC services, embeds the
profile and its entitlement when the profile exists, and produces a signed DMG.
Apple checks every binary, not only the outer app.

`make notarize` first verifies each Mach-O in the image for a Developer ID
authority and a timestamp, submits, waits, and stops with Apple's log if the
status is anything but Accepted. Then it staples the ticket, so a Mac can
validate the download offline, and asks Gatekeeper for a verdict.

`make appcast` runs Sparkle's `generate_appcast` over every DMG in `dist/`, so
the feed keeps its history, embeds the `## <version>` section of `CHANGELOG.md`
as the release notes, and writes `dist/appcast.xml`. The first run asks for
access to the signing key; answer Always Allow.

## Why the updater is opt-in at build time

macOS loads a framework into a process only when both carry the same Apple team
identifier. An ad-hoc or self-signed build has none, so a build carrying
Sparkle dies at launch unless signed with a real identity. `make app`, the tests
and CI therefore build without it; `make release` builds with it.

## Verify like a user

Passing `spctl` on the machine that built the app proves little, because that
Mac already trusts it. Simulate a download:

```bash
cp dist/Clipvelope-<version>.dmg /tmp/downloaded.dmg
xattr -w com.apple.quarantine "0083;$(printf '%x' "$(date +%s)");Safari;$(uuidgen)" /tmp/downloaded.dmg
spctl -a -vv -t open --context context:primary-signature /tmp/downloaded.dmg
# expect: accepted, source=Notarized Developer ID
```

## Publishing

Upload the DMG and `dist/appcast.xml` to the location `SUFeedURL` in
`Resources/Info.plist` points at. That URL must be reachable without
authentication; GitHub does not serve release assets from a private repository
to anonymous clients, and Sparkle fails quietly when a check cannot reach the
feed. `Clipvelope --status` reports whether the feed answers with an appcast.

## Checklist

1. Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist`.
2. Add the `## <version>` section to `CHANGELOG.md`; CI refuses a version without one.
3. `make check && make test`.
4. `make release`, then notarize the app, rebuild the image, notarize the image,
   then the quarantined check above. Notarizing the app before the image is
   built is what lets a first launch succeed with no network: the app carries
   its own ticket instead of having to ask Apple.
5. `make appcast`, publish the DMG and the appcast together.

## The vault across updates

Users carry their encrypted history from one version to the next. Two
properties protect it and have regression tests: `AppState` and `ClipboardItem`
decode field by field with defaults, so a new field never makes an old vault
undecodable; and storage distinguishes "no vault yet" from "cannot read this
vault" and refuses to write over the second.
