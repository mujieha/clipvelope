# Changelog

Release notes for Clipvelope. Sparkle shows the section for a version in its
update prompt; `make appcast` takes it from here.

## 0.1.0

First release.

- Clipboard history for text, formatted text, images and files, encrypted at
  rest with AES-GCM and stored only on this Mac.
- Menu bar panel grouped by time, with search, autocomplete and full keyboard
  control: Control + Option + V opens it from any app, arrows and Return copy.
- Quick Slots: Option + 1 to 9 paste a snippet or a shell command's output from
  anywhere.
- Skips passwords and one-time codes that password managers mark as concealed,
  unless you explicitly switch that off.
- Encrypted backups, device-bound or portable with a password, and an automatic
  backup after every change.
- Refuses to overwrite a vault it cannot read, and says so.
- Every encrypted file is bound to its role, the index or one specific item's
  payload, so a file written for one purpose cannot be passed off as another.
  Vaults from pre-release builds are rebound on first launch; their headerless
  backups are no longer readable and should be exported again.
- `Clipvelope --open` and `--preferences` act only on requests carrying a token
  held in the app's own Keychain item, so no other process can pop the history
  open.
- Importing a portable backup leaves this Mac's own choices alone: it cannot
  switch automatic backups on or off, change their mode, rebind shortcuts, or
  add file rows, which would otherwise hand a paste target any file whose path
  the backup's author guessed.
- Hostile input is refused before it costs anything: a backup may demand at most
  ten million key-derivation rounds, an image is checked against its declared
  pixel count before decoding, and formatted text with an oversized plain
  rendering is skipped like oversized plain text.
