# Changelog

Release notes for Clipvelope. Sparkle shows the section for a version in its
update prompt; `make appcast` takes it from here.

## 0.2.0

### New

- Paste directly: choosing an entry can put it straight into the app you were
  typing in, instead of copying it for you to paste. It is off by default, and
  because it presses Command + V for you it needs macOS Accessibility access,
  which you grant yourself in System Settings; Preferences → Privacy says what
  that permission covers. Option + Return pastes with formatting dropped.
- The daily update check is now a setting. Turn "Check for updates
  automatically" off in Preferences → General and Clipvelope makes no network
  call at all until you press Check for Updates.
- The panel stops at fifty rows, and now says how many more entries there are
  beyond them — while you are searching, how many more matches — instead of
  ending with no explanation.
- VoiceOver reads the panel and Preferences: history rows say what they hold,
  and the icon-only buttons say what they do rather than announcing as
  "button".
- When something goes wrong while the panel is closed, Clipvelope says so in a
  small panel below the menu bar, and says what to do about it. Click it to
  send it away, or leave it and it goes on its own. Nothing is shown when a
  paste works: the text appearing where you were typing is the message. It
  needs no notification permission.

### Better

- Search and autocomplete no longer slow down as the history fills up.
- Search ignores accents, so "resume" finds "résumé" and "résumé" finds
  "resume".
- Less battery: the clipboard is checked less often while nothing is being
  copied.

### Fixed

- Two different images that happened to share the same dimensions, size and
  type were treated as the same entry: the second one was dropped and the
  older picture shown under a new timestamp. They are now told apart by their
  contents. Formatted text had the same flaw.
- Opening Clipvelope while it is already running no longer leaves you with two
  copies. Two of them fought over the global shortcuts, and Preferences then
  blamed another app for taking them; the second copy now hands over to the
  first and quits. This applies within your own login only, so someone else
  logged into the same Mac still gets their own Clipvelope.
- Control + Option + V no longer depends on an internal name inside macOS that
  a system update could change, which would have left the app looking broken
  with no way in.
- Paste directly now refuses to paste anywhere but the application you were in
  when you chose the entry. Picking an image or a formatted entry can take a
  moment, and if you switched apps during it the entry — which may be a
  password — used to be typed into whatever you had switched to.
- Paste directly also refuses if something else has taken the clipboard in the
  meantime, such as a Quick Slot command finishing, instead of pasting that
  other thing and saying nothing about it.
- Every message about a paste that did not happen, and every Quick Slot
  failure, was written into the history panel — which is closed at exactly
  those moments, so no one ever saw one. They now reach you where you are.
- A history made entirely of pinned entries stopped Clipvelope recording
  anything at all, silently: nothing could be trimmed to make room, so each new
  copy was thrown away the moment it arrived. Importing a backup was enough to
  arrange it. Whatever the history holds, what you copy next is now kept, and a
  backup may leave at most 199 of its entries pinned. A vault already in that
  state starts recording again as soon as you open it.
- Importing a backup while your vault could not be read — the situation the
  import is there to rescue — put the restored pictures and formatted entries
  aside along with the old vault, so they all came back broken. They are now
  written after the old vault is set aside, and the old one is still kept.
- A backup could understate how large an entry's picture was, which quietly
  left that picture out of every backup you made afterwards. The stored bytes
  are now checked against what the entry claims about them.
- Bytes another app offered as a PNG are no longer stored as one without
  checking. They could not be read back, so the entry deleted itself later,
  saying its file was missing.
- Quitting waits, briefly, for the last thing you copied to reach the vault.

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
