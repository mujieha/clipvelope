# Security

Clipvelope stores clipboard history, which can include anything a person copies.
Its whole purpose is to keep that on the machine and unreadable to anyone else,
so a security report is the most useful issue this project can receive.

## Reporting a vulnerability

Please do not open a public issue for a vulnerability. Use GitHub's private
vulnerability reporting on this repository: **Security → Report a vulnerability**.
You will get an acknowledgement within a few days and a fix or a reasoned
answer as fast as the problem warrants; the report stays private until a fix is
released, and you will be credited in the changelog unless you prefer not to be.

## What is in scope

- Anything that lets another process, user or machine read clipboard history or
  the encryption key: the vault files under `~/Library/Application Support`, the
  Keychain items, backups, the auto-backup file.
- Anything an imported backup can make the app do that the user did not choose,
  such as running a command or weakening a privacy setting.
- The update path: a way to make the app accept an update not signed with the
  project's key, or to make it contact anything other than the feed URL.
- Concealed content (passwords, one-time codes) being recorded while the
  "capture sensitive content" setting is off.

## What the design already claims

- History and images are encrypted at rest with AES-GCM; the key lives in the
  macOS Keychain, in the data protection keychain for signed builds.
- Nothing is sent anywhere. A release build contacts the update feed once a day
  and sends nothing about the user or the clipboard.
- A vault that cannot be decrypted is never overwritten.
- Every encrypted file is bound to its role, the index or the payload of one
  specific item, so a file the app wrote for one purpose cannot be presented
  to it as another, and a backup must carry its header.
- `Clipvelope --open` and `--preferences` act only on requests that carry the
  token this launch stored in the app's Keychain item; a bare notification on
  the same name is ignored.
- Portable backups disable the shell flag on every imported command and cannot
  weaken privacy settings.

If you can show one of those claims to be false, that is a vulnerability.
