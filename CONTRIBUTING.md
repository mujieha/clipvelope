# Contributing

Clipvelope runs on **macOS 26 or later** and builds with Swift Package Manager
and the Xcode 26 toolchain. 26 is a floor, not a target: it is the oldest system
the app supports and every later one is supported too. There are no
compatibility shims for anything older, and pull requests adding them will be
declined.

The floor is enforced by the compiler rather than by convention. `Package.swift`
declares `.macOS("26.0")`, `LSMinimumSystemVersion` is `26.0`, and CI checks the
two agree, so there is not a single `#available` in the tree — anything that
needed one would not compile.

```bash
make test     # the XCTest suite; points DEVELOPER_DIR at Xcode for XCTest
make check    # workflow shell syntax and property lists
make app      # dist/Clipvelope.app, signed ad-hoc unless CODESIGN_IDENTITY is set
make run      # rebuild and relaunch the menu bar app
make smoke    # launches the built app and checks the panel and Preferences open
```

`swift build` on its own produces a bare executable that cannot be a menu bar
app; use `make app`. It also deletes `Package.resolved`, because the default
build has no dependencies: run `git checkout Package.resolved` before committing.

## What a change needs

- Tests for anything in `Models`, `Storage`, `BackupCodec`, `Policies` or
  `Presentation`; CI holds those files above 85% line coverage.
- No new state the user cannot tell apart from another state. Loading, empty,
  failed and paused must each look different. Prefer an enum to a boolean when
  the code knows more than yes or no.
- A `CHANGELOG.md` entry under the upcoming version for anything a user would
  notice.
- Nothing personal in commits or files: no home paths, email addresses, session
  identifiers or Apple team identifiers.

Open pull requests against `develop`. CI runs the full suite, builds the bundle
and launches it on a macOS runner.
