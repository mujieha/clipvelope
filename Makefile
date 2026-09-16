.PHONY: build test app run clean icon check preflight xcodeproj dmg notarize release appcast smoke

build:
	swift build

test:
	./scripts/test.sh

# Everything CI checks that does not need a build.
#
# The appcast self-test belongs here rather than in `make appcast`: it proves the
# URL rule and the rewrite against a synthetic feed, so it needs no signing key,
# no Sparkle build and no disk image -- and the update channel is the one place
# where a mistake reaches every installed copy. Without this the rule was only
# ever exercised by hand.
check:
	./scripts/check-workflows.sh
	plutil -lint Resources/Info.plist Resources/Clipvelope.entitlements
	CLIPVELOPE_APPCAST_SELFTEST=1 ./scripts/make-appcast.sh

# Read-only. Refuses a release whose version, changelog, build number or dist/
# contents are wrong. Run it before `make release`.
preflight:
	./scripts/preflight.sh

app:
	./scripts/bundle.sh

# Launches dist/Clipvelope.app and checks the panel and Preferences open.
smoke: app
	./scripts/smoke.sh

# Only needed to obtain or refresh a provisioning profile; the real build is
# `make app`. Pass your team identifier: make xcodeproj TEAM=XXXXXXXXXX
xcodeproj:
	python3 scripts/make-xcodeproj.py $(TEAM)

# The app icon is compiled from Resources/Clipvelope.icon on every `make app`.
# This regenerates the two derived assets: the menu bar template and the
# GitHub social preview, rendered from the built app's icon.
icon: app
	swift scripts/make-menubar-icon.swift Resources/MenuBarIcon.pdf
	swift scripts/render-app-icon.swift dist/Clipvelope.app dist/Clipvelope.icns docs/images/social-preview.png

dmg:
	./scripts/make-dmg.sh

# Rebuild the disk image around the app already sitting in dist/, without
# rebuilding the app itself.
#
# This is the step that follows notarizing the app, and it cannot be `make dmg`:
# that rebuilds, which throws away the notarization staple just applied and --
# because it does not set CLIPVELOPE_SPARKLE -- drops the updater as well. The
# result looks correct and is not, which is exactly the kind of release mistake
# this project keeps finding after the fact.
repack:
	CLIPVELOPE_SPARKLE=1 SKIP_BUILD=yes ./scripts/make-dmg.sh

# A build with the updater. Needs a real Apple identity: macOS will not load an
# embedded framework into an ad-hoc signed process.
#
# The release recipe is: preflight, release, notarize, appcast.
release:
	CLIPVELOPE_SPARKLE=1 ./scripts/bundle.sh
	CLIPVELOPE_SPARKLE=1 SKIP_BUILD=yes ./scripts/make-dmg.sh

appcast:
	./scripts/make-appcast.sh

# Requires a Developer ID identity and notarytool credentials.
# Usage: make notarize TARGET=dist/Clipvelope-0.1.0.dmg
notarize:
	./scripts/notarize.sh $(TARGET)

run: app
	@pkill -f 'Clipvelope.app/Contents/MacOS/Clipvelope' 2>/dev/null || true
	open dist/Clipvelope.app
	@echo "Clipvelope is running in the menu bar."

clean:
	rm -rf .build dist
