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
make preflight                                    # read-only; refuses a tree that is not ready
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" make release
make notarize TARGET=dist/Clipvelope.app          # staple the app first
make dmg                                          # image now holds a stapled app
make notarize TARGET=dist/Clipvelope-<version>.dmg
make appcast
```

`make preflight` reads the tree and refuses a release it is not ready for. It
runs every check and reports all of them rather than stopping at the first:

- `Package.swift`'s platform version and `LSMinimumSystemVersion` agree.
- `CHANGELOG.md` has a `## <version>` section and that section is not empty.
- `CFBundleVersion` is an integer and is strictly greater than the one the most
  recent `v*` tag shipped. Skipped, not failed, while the version string is
  still the tagged one — that is the normal state between releases.
- `SUPublicEDKey` and `SUFeedURL` are set.
- `dist/` holds at most one `.dmg`, and its filename version matches the tree.
  Two images is the trap that nearly signed a stale 0.1.0 into the feed.
- The working tree has no uncommitted changes to tracked files, so the build can
  be reproduced. `PREFLIGHT_ALLOW_DIRTY=1` waives this one, and only this one.

CI runs the build-number check on its own, after the changelog check, because
`dist/` and the working tree mean nothing on a runner. It is skipped when the
clone has no tags, so a fork still passes.

Why the build number matters more than it looks: Sparkle compares
`CFBundleVersion`, not `CFBundleShortVersionString`. A 0.2.0 built with the
build number still at `1` is never offered to anyone running 0.1.0, and Sparkle
reports nothing at all — their copy simply goes on looking current.

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

### Every image is advertised under its own tag

`generate_appcast` takes exactly one `--download-url-prefix` and applies it to
everything it writes, but the feed carries an item per disk image and each image
lives under its own release tag. Left alone, the first release with a
predecessor advertises `Clipvelope-0.1.0.dmg` at `.../download/v0.2.0/…` — a 404
aimed precisely at the people who have not updated yet, and one Sparkle reports
as nothing more than a failed check. So `make appcast` rewrites each
`<enclosure url=…>` from that file's own name after the tool has run. The
signature beside it covers the disk image's bytes rather than the feed's, so
rewriting the URL leaves it valid; the script checks that it stayed untouched.

`CLIPVELOPE_DOWNLOAD_PREFIX` still overrides everything, unchanged, for
downloads hosted somewhere other than GitHub releases — there the operator has
said where the files are and there is only one place.

Prove the rule without a signing key, a Sparkle build or a disk image:

```bash
CLIPVELOPE_APPCAST_SELFTEST=1 ./scripts/make-appcast.sh
```

It prints the URL two made-up releases would get, then rewrites a feed shaped
like the real one and checks each item came back under its own tag with its
signature intact.

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
   `CFBundleVersion` must go up, or the update reaches nobody.
2. Add the `## <version>` section to `CHANGELOG.md`; CI refuses a version without one.
3. `make check && make test`.
4. Commit, then `make preflight`. It must print `ready to release`; it checks the
   working tree is clean, so run it after the commit and not before.
5. `make release`, then notarize the app, rebuild the image, notarize the image,
   then the quarantined check above. Notarizing the app before the image is
   built is what lets a first launch succeed with no network: the app carries
   its own ticket instead of having to ask Apple.
6. `make appcast`, publish the DMG and the appcast together.

## The vault across updates

Users carry their encrypted history from one version to the next. Two
properties protect it and have regression tests: `AppState` and `ClipboardItem`
decode field by field with defaults, so a new field never makes an old vault
undecodable; and storage distinguishes "no vault yet" from "cannot read this
vault" and refuses to write over the second.
