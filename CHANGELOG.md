# Changelog

Release notes for Clipvelope. Sparkle shows the section for a version in its
update prompt; `make appcast` takes it from here.

## 0.1.0

First release.

### What it does

- Clipboard history for text, formatted text, images and files, encrypted at
  rest with AES-GCM and stored only on this Mac.
- Menu bar panel grouped by time, with search, autocomplete and full keyboard
  control: Control + Option + V opens it from any app, arrows and Return copy.
  Both shortcuts can be changed.
- Quick Slots: Option + 1 to 9 paste a snippet, or the output of a shell command,
  from anywhere.
- Skips passwords and one-time codes that password managers mark as concealed,
  unless you explicitly switch that off.
- Encrypted backups, device-bound to this Mac or portable with a password, and
  an optional automatic backup after every change.

### What it guarantees

- Nothing is transmitted. The only copy that can leave this Mac is one you ask
  for: automatic backup writes to `~/Documents`, which iCloud syncs if you use
  Desktop & Documents sync, and what syncs is ciphertext.
- A vault that cannot be read is never overwritten, and saving pauses until you
  decide what to do. Setting one aside keeps it, images and all.
- Every encrypted file is bound to its purpose, the index or one specific
  entry's contents, so a file written for one purpose cannot be presented to the
  app as another.
- A backup from someone else is treated as untrusted input throughout. It cannot
  arm a shell command behind a hotkey, weaken your privacy settings, change
  whether or where backups are written, rebind your shortcuts, plant references
  to files on your disk, or install more text than the app itself would hold.
- Hostile input is refused before it costs anything: an image is checked against
  the size its own header declares before any of it is decoded, and a backup
  cannot dictate how much work opening it takes.
- `Clipvelope --open` and `--preferences` ignore requests that do not carry a
  token this launch keeps in the app's Keychain item. Read "Known limits" in
  SECURITY.md for what that is worth: it stops a process that merely posts a
  notification, and it is not a security boundary.

### If you tested a pre-release build

Vaults and backups written by those builds cannot be opened by this one, and the
app will say so rather than blaming your Keychain. Those builds stored each
entry without binding it to its purpose, and any program running as you could
choose what got stored by writing to the clipboard, so a vault of that vintage
cannot be told apart from one an attacker assembled. The old files are kept
beside the new ones rather than deleted.
