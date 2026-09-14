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
- Clipvelope transmits nothing. A release build contacts the update feed once a
  day and sends nothing about the user or the clipboard; turning off "Check for
  updates automatically" in Preferences → General stops even that, and the app
  then contacts nothing at all until Check for Updates is pressed by hand. Auto
  backup, which is off until the user enables it, writes an encrypted file to
  `~/Documents`; if they use iCloud Desktop & Documents sync, that ciphertext is
  copied to their own iCloud account. Nothing else can leave the machine.
- A vault that cannot be decrypted is never overwritten.
- Every encrypted file this version writes is bound to its role, the index or
  the payload of one specific item, so a file the app wrote for one purpose
  cannot be presented to it as another, and a backup must carry its header. A
  vault written before 1.0 carries no role, and rather than accept one this
  version refuses to open it and says so: those builds sealed clipboard payloads
  with no role too, and a payload's contents are chosen by whoever writes the
  pasteboard, so accepting an unbound file would let one be copied over the
  index and applied as vault state.
- `Clipvelope --open` and `--preferences` ignore a bare notification on their
  name; a request must carry the token this launch stored in the app's Keychain
  item. Read the first known limit below for what that does and does not buy.
- Portable backups disable the shell flag on every imported command and cannot
  weaken privacy settings, change whether or where this Mac writes its own
  backups, rebind shortcuts, or plant file references.
- No backup can stop Clipvelope recording what you copy next. What one may
  install is bounded, but not by the size of the live history: up to 1,000
  entries and 32 MB of text, against the 200 entries the history itself keeps,
  and pictures bounded at 32 MB each and in total only by the size of the file
  you chose to import. The surplus is ordinary history, and the first copies you
  make afterwards trim it away. What a backup cannot do is take that room away
  for good: pinned entries are exempt from trimming, so no more than 199 of the
  entries an import installs stay pinned, one short of the cap, and the entry a
  copy adds is never the one trimmed to make room. Whatever a backup contained,
  the next thing you copy is still recorded.

If you can show one of those claims to be false, that is a vulnerability.

## Known limits

These are understood and deliberate. A report that restates one is welcome as a
suggestion, but it is not a vulnerability report.

- **`--open` is not a security boundary.** Anything running as your macOS user
  can execute Clipvelope's own binary, and that binary can read the token that
  authenticates the request, so it can open the panel. The token stops a process
  that merely posts a notification, which costs an attacker nothing; it cannot
  stop one that runs the app. No peer check would change this, because the
  caller really is Clipvelope. Displaying the panel discloses history only to
  something that can also read the screen, which macOS gates behind Screen
  Recording or Accessibility consent.
- **An unsigned build protects nothing from other programs you run.** Without a
  signing identity there is no data protection keychain, so both the vault key
  and that token live in the file keychain, which any program you run can read.
  `Clipvelope --status` reports which keychain is in use.
- **Neither the vault nor the auto-backup file has a rollback counter.** Each
  file authenticates its own role, so contents cannot be forged or swapped
  between roles, but anyone who can write the vault directory can restore an
  older copy of files they took from it earlier and return your history to that
  earlier state. The auto-backup file is a second such surface and a softer one:
  it sits in `~/Documents` rather than Application Support, it is mirrored into
  your iCloud account if you use Desktop & Documents sync, and restoring it is a
  button in Preferences. When it is written with this Mac's own key, which is
  the default, it is restored as your own data and not disarmed the way a
  portable backup is, so a rollback there reaches your settings as well as your
  history: pasting directly, the shell flag on every Quick Slot and folder
  command, password-skipping, the ignored-apps list, both shortcuts, and the
  auto-backup settings themselves. What bounds this is that a rollback can only
  put back a state you were once in. It can return a shell command you once
  had; it cannot invent one, or switch on something you never enabled.
- **Direct paste means holding Accessibility access, which is broad.** Posting
  Command + V for you requires it, and macOS grants it whole: an app holding it
  can observe and control other applications, and nothing in the grant narrows
  it to one keystroke. Clipvelope posts that one keystroke and nothing else, but
  that is a property of this build's code, not something the permission
  enforces. What protects you is that the permission is yours: the setting is
  off until you turn it on in Preferences → Privacy, the app asks for nothing
  until then, importing a portable backup cannot turn it on, and you grant and
  revoke the access in System Settings → Privacy & Security → Accessibility,
  where turning the setting back off does not revoke it for you.
