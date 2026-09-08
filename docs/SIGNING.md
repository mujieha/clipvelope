# Code signing

`scripts/bundle.sh` signs `dist/Clipvelope.app`. By default it signs **ad-hoc**
(`codesign --sign -`), because that needs no account, no certificate and no
setup. This document is about when that is enough and when it is not.

## What ad-hoc actually costs you

Measured on macOS 26.6.2, with this app:

| | ad-hoc | real identity |
|---|---|---|
| Runs on the machine that built it | yes | yes |
| Keychain key readable after a rebuild | yes | yes |
| Launch at Login (`SMAppService`) registers | yes | yes |
| **Vault key private to Clipvelope** | **no** | **yes** |
| Runs for another user / another Mac | no | yes |
| Can be notarized | no | Developer ID only |
| Stable designated requirement | no | yes |

The bold row is the one that matters, and it is the reason to bother with any of
this. **An ad-hoc build cannot keep its encryption key from other applications
running as the same user.**

### Why the file keychain cannot protect the key

The obvious fix is a trusted-application ACL: `SecAccessCreate` with only this
app in the trusted list, passed as `kSecAttrAccess`. The ACL is written exactly
as intended —

```
entry 1:
    authorizations (6): decrypt derive export_clear export_wrapped mac sign
    applications (1):
        0: .../scratchpad/acl (OK)
            requirement: cdhash H"8015fb5b..."
```

— and it does not work. A completely unrelated binary read the secret with
status 0, no prompt, and macOS then *appended that binary to the ACL*:

```
entry 1:
    applications (2):
        0: .../scratchpad/other (OK)     <- added by the system, unprompted
        1: .../scratchpad/acl (OK)
```

The same thing has been happening to Clipvelope's own key: its ACL had
accumulated nine cdhash entries, one per build. Legacy `SecKeychain` ACLs are
deprecated and, on current macOS, not enforced for this case. Implementing them
would add deprecated API and warnings for no protection at all, so Clipvelope
does not.

### What does work

The **data protection keychain** (`kSecUseDataProtectionKeychain`) scopes items
to the app's keychain access group, which is derived from the team identifier in
the code signature. That genuinely restricts access — and it is unavailable
without a real identity:

```
data-protection SecItemAdd:   -34018  (A required entitlement isn't present)
SecAccessControl SecItemAdd:  -34018  (same)
```

`keychain-access-groups` is a **restricted** entitlement. The kernel kills any
process carrying one that is not authorised by an **embedded provisioning
profile**, and a signing certificate on its own does not authorise it. Measured
here, on macOS 26:

| Signing | Entitlement | Launches? | Key storage |
|---|---|---|---|
| ad-hoc | yes | no — SIGKILL, exit 137 | — |
| self-signed | yes | no — SIGKILL, exit 137 | — |
| self-signed | no | yes | file keychain |
| Apple Development | yes, `TEAMID.com.mujieha.Clipvelope` | **no — SIGKILL, exit 137** | — |
| Apple Development | no | yes | file keychain |

So a certificate is necessary and **not sufficient**. Isolating the vault key
needs a provisioning profile as well, which is why `scripts/bundle.sh` applies
the entitlement only when one is present, and refuses to hand back an app that
will not launch.

Note the entitlement value must carry the team identifier —
`TEAMID.com.mujieha.Clipvelope`, not the bare bundle id. `bundle.sh` substitutes
it from the OU of the signing certificate. Be careful reading that identifier by
eye: an Apple Development certificate's common name ends in a parenthesised code
that is **not** the team identifier. The team is the OU.

## Getting a provisioning profile

Only Xcode will mint one, which is the entire reason this repository carries an
Xcode project it does not otherwise need:

```bash
make xcodeproj TEAM=XXXXXXXXXX     # your team identifier: the OU of the certificate
xcodebuild -project Clipvelope.xcodeproj -scheme Clipvelope \
    -destination 'platform=macOS' -allowProvisioningUpdates build
cp ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/*.provisionprofile \
   Resources/embedded.provisionprofile
```

`scripts/bundle.sh` embeds `Resources/embedded.provisionprofile` when it exists
and applies the entitlement only then. Confirmed working: the profiled build
reports `key storage: data protection keychain (private to this app)`.

The generated profile authorises `keychain-access-groups = TEAM.*`, which covers
the group the app asks for.

### The seven-day catch on a free account

A profile issued to a **free** Apple ID expires after **seven days**. A paid
Developer Program membership gets a year.

This matters more than it sounds, because migration is one-way. The first time a
profiled build runs, it moves the vault key into the data protection keychain
and removes the copy from the file keychain — that removal is the whole point,
since a copy left behind would still be readable by anything. Afterwards only a
build carrying a valid profile can read the vault. When the profile lapses, the
history is unreadable until a fresh one is minted by repeating the steps above.

So on a free account the choice is:

- **Renew weekly.** Re-run the two commands above; the vault keeps working and
  the key stays private.
- **Stay unmigrated.** Do not put a profile in `Resources/`. The app runs signed
  with a stable designated requirement, and says plainly in Preferences that the
  key is not isolated.
- **Pay for the Developer Program**, and renew yearly instead.

Whichever you pick, export a password-protected backup first (Preferences →
Backup → Export (Password)). It is encrypted with a password rather than the
Keychain key, so it can be restored no matter what happens to the profile.

The migration itself is written to be safe: the key is written to the data
protection keychain, read back and compared, and only then removed from the file
keychain. A failed write leaves the original in place and the app carries on.

So Clipvelope does the following, and `scripts/bundle.sh` applies the entitlement
only when `CODESIGN_IDENTITY` is set:

- Probes once, **with a write**, whether the data protection keychain is
  available. A read is not a valid probe: looking up a nonexistent item returns
  `errSecItemNotFound` either way, and only a write reports the missing
  entitlement.
- Uses it when available, so the key is private to the app.
- Falls back to the file keychain otherwise, and says so — in the log, and in
  `Clipvelope --status`:

```
key storage:      file keychain (READABLE BY ANY APP YOU RUN)
                  sign the app to fix this - see docs/SIGNING.md
```

- Migrates an existing key from the file keychain into the data protection
  keychain the first time it can, so signing the app does not strand the vault.

The upshot: **getting a signing identity is what makes the vault's key private.**
Until then the encrypted file protects against someone reading the disk, but not
against another process on the same account asking the Keychain for the key.

## When you do need an identity

- **Giving the app to anyone else.** Gatekeeper refuses ad-hoc-signed apps that
  arrive with a quarantine flag. This is the common case.
- **Notarizing.** Requires a paid Developer ID certificate.
- **Hardened runtime with entitlements.** The bundle script already passes
  `--options runtime`; entitlements on top of that need a real identity.
- **Keeping the vault key private to Clipvelope**, per the section above. This is the strongest reason.

## Option A — free Apple ID (an "Apple Development" certificate)

Costs nothing and needs no Developer Program membership. Good enough for a
stable local identity.

1. Open Xcode → **Settings** → **Accounts**.
2. Click **+**, choose **Apple ID**, sign in with any Apple ID.
3. Select the account, click **Manage Certificates…**.
4. Click **+** → **Apple Development**.

Then confirm the identity exists and build with it:

```bash
security find-identity -v -p codesigning
# 1) ABCD… "Apple Development: you@example.com (TEAMID)"

CODESIGN_IDENTITY="Apple Development: you@example.com (TEAMID)" make app
```

`scripts/bundle.sh` picks the identity up automatically when it is the only one
available, so once this is set up `make app` is usually enough.

Caveat: Apple Development certificates are for development. They do not let you
distribute the app to other people — that needs Option C.

## Option B — a self-signed certificate (no Apple account at all)

Gives a stable designated requirement without any Apple relationship. It does
**not** help with distribution — macOS will not trust it on any other machine —
and, per the table above, it does **not** unlock the data protection keychain,
so the vault key stays readable by other apps. Use Option A for that; it is also
free.

1. Open **Keychain Access**.
2. Menu **Keychain Access** → **Certificate Assistant** → **Create a
   Certificate…**.
3. Name it (e.g. `Clipvelope Local Dev`), Identity Type **Self Signed Root**,
   Certificate Type **Code Signing**. Create it.

```bash
CODESIGN_IDENTITY="Clipvelope Local Dev" make app
```

Note that `security find-identity -v -p codesigning` will **not** list a
self-signed certificate — `-v` means "valid", and a self-signed root is
untrusted, so it reports `CSSMERR_TP_NOT_TRUSTED` and the count comes back
zero. `codesign` signs with it regardless. Drop the `-v` to see it:

```bash
security find-identity -p codesigning
```

Because it does not show up as valid, `scripts/bundle.sh` will not auto-detect
it; pass `CODESIGN_IDENTITY` explicitly.

## Option C — Developer ID (distribution)

Requires the paid Apple Developer Program.

1. Xcode → Settings → Accounts → Manage Certificates → **+** →
   **Developer ID Application**.
2. Build, then notarize and staple:

```bash
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" make app
ditto -c -k --keepParent dist/Clipvelope.app dist/Clipvelope.zip
xcrun notarytool submit dist/Clipvelope.zip \
    --apple-id you@example.com --team-id TEAMID --wait
xcrun stapler staple dist/Clipvelope.app
```

Notarization requires the hardened runtime, which the bundle script already
enables.

## Troubleshooting

**`codesign` fails with `errSecInternalComponent`, and `security find-identity -v
-p codesigning` reports 0 valid identities even though the certificate is in the
keychain.** The chain cannot be built. Check the Apple Worldwide Developer
Relations intermediate:

```bash
security find-certificate -a -c "Apple Worldwide Developer Relations" -p \
  | openssl x509 -noout -subject -dates
```

The original WWDR intermediate expired on 7 February 2023 and a Mac that has
been around a while may still carry only that one, in the system keychain. The
current one is G3, valid to 2030:

```bash
curl -O https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer
security add-certificates -k ~/Library/Keychains/login.keychain-db AppleWWDRCAG3.cer
```

Adding it to the login keychain is enough; it inherits trust from the Apple Root
CA, which macOS already trusts, so no trust settings need changing and no admin
rights are required. `codesign` warns "unable to build chain to self-signed root"
before this and signs cleanly after.

## Verifying what you built

```bash
# Which identity signed it, and what the requirement is
codesign -dv --verbose=2 dist/Clipvelope.app
codesign -d -r- dist/Clipvelope.app

# Is the signature intact
codesign --verify --strict --verbose=2 dist/Clipvelope.app

# Would Gatekeeper accept it (fails for ad-hoc and self-signed; expected)
spctl -a -vvv -t exec dist/Clipvelope.app

# What the app itself can see
dist/Clipvelope.app/Contents/MacOS/Clipvelope --status
```
