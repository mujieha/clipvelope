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
export CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
make preflight                                    # read-only; refuses a tree that is not ready
make release
make notarize TARGET=dist/Clipvelope.app          # staple the app first
make repack                                       # image built around the stapled app
make notarize TARGET=dist/Clipvelope-<version>.dmg
make appcast
```

Two things about that sequence that have each cost a release.

`CODESIGN_IDENTITY` must be the certificate's **common name**, exported so every
step sees it. `bundle.sh` reads the team identifier out of the certificate by
that name, so a SHA-1 hash — which `codesign` itself accepts — makes it fail
with no message. And `make-dmg.sh` signs the image only when it is set, so an
identity given to `make release` alone leaves you notarizing an unsigned image.

`make repack`, not `make dmg`. `make dmg` rebuilds the app, which discards the
notarization staple applied the step before and, because it does not set
`CLIPVELOPE_SPARKLE`, drops the updater too. The image still builds and still
looks right.

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
rewriting the URL leaves it valid; the self-test below checks that it stayed
untouched, and `make check` runs it, so every CI run checks it too.

`CLIPVELOPE_DOWNLOAD_PREFIX` still overrides everything, unchanged, for
downloads hosted somewhere other than GitHub releases — there the operator has
said where the files are and there is only one place.

Prove the rule without a signing key, a Sparkle build or a disk image:

```bash
CLIPVELOPE_APPCAST_SELFTEST=1 ./scripts/make-appcast.sh
```

It prints the URL two made-up releases would get, then rewrites a feed shaped
like the real one and checks each item came back under its own tag with its
signature intact. `make check` runs exactly this, so it needs no build, no
signing key and no disk image, and CI runs the same script on every push.

## Which macOS the checks actually run on

`LSMinimumSystemVersion` is 26.0, so the app runs on macOS 26 and everything
after it. Both ends need testing, and they are not interchangeable: 0.2.0
development produced a commit that passed every check on macOS 26 and, on macOS
27, opened nothing at all — SwiftUI's `MenuBarExtra` stopped wiring its status
item's target and action there, so the keyboard shortcut and `--open`, the only
two ways into the app, became silent no-ops. No headless test can see that. Only
launching the app on that OS can, which is what `make smoke` does.

- **macOS 26** is covered by `.github/workflows/ci.yml` on GitHub's hosted
  runners, on every push and every pull request. The matrix there has a
  `macos-27` entry written out and commented, ready for the day that image
  exists; hosted runners currently stop at 26.
- **macOS 27** is covered by `.github/workflows/ci-macos27.yml` on a self-hosted
  runner. It deliberately has no `pull_request` trigger: this repository is
  public, and that trigger is the one thing that would let a fork run code on a
  real machine. Pull requests belong on the hosted runners.

A self-hosted runner for this project has to run as a **login item in a graphical
session**, not as a system daemon — `make smoke` launches a real app and needs a
window server. If the runner's user is logged out, jobs queue rather than fail.

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
5. `make release`, notarize the app, `make repack`, notarize the image, then the
   quarantined check above. Notarizing the app before the image is built is what
   lets a first launch succeed with no network: the app carries its own ticket
   instead of having to ask Apple. `make repack` rather than `make dmg` — see
   the note under Commands.
6. `make appcast`, publish the DMG and the appcast together.
7. Before publishing, rehearse the update itself. Serve `dist/` over HTTP,
   regenerate the feed against it with
   `CLIPVELOPE_DOWNLOAD_PREFIX=http://localhost:<port>/`, point a copy of the
   *previous* release at it with
   `defaults write com.mujieha.Clipvelope SUFeedURL http://localhost:<port>/appcast.xml`,
   and let it update. Sparkle refuses a `file://` feed, so it has to be served.
   Delete that default afterwards, or the installed app keeps asking a server
   that is no longer there. This is the only check that proves the thing a
   release exists to do, and every part of it fails silently.

## The vault across updates

Users carry their encrypted history from one version to the next. Two
properties protect it and have regression tests: `AppState` and `ClipboardItem`
decode field by field with defaults, so a new field never makes an old vault
undecodable; and storage distinguishes "no vault yet" from "cannot read this
vault" and refuses to write over the second.
