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
