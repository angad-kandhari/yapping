APP      := .build/Yapping.app
BINARY   := .build/arm64-apple-macosx/release/yapping
# Developer ID first (notarizable, downloads pass Gatekeeper); fall back to
# Apple Development for machines that only have the free-tier cert
IDENTITY := $(shell security find-identity -v -p codesigning | grep -o '"Developer ID Application[^"]*"' | head -1)
ifeq ($(IDENTITY),)
IDENTITY := $(shell security find-identity -v -p codesigning | grep -o '"Apple Development[^"]*"' | head -1)
endif

.PHONY: build bundle sign notarize install run clean

build:
	swift build -c release --arch arm64

bundle: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(BINARY) $(APP)/Contents/MacOS/yapping
	cp Support/Info.plist $(APP)/Contents/
	cp Support/AppIcon.icns $(APP)/Contents/Resources/

# A stable (non ad-hoc) signature keeps TCC grants valid across rebuilds.
# Hardened runtime + timestamp + entitlements are what notarization demands;
# they are harmless for local dev builds too.
sign: bundle
ifneq ($(IDENTITY),)
	codesign --force --options runtime --timestamp \
		--entitlements Support/Yapping.entitlements --sign $(IDENTITY) $(APP)
else
	@echo "no signing identity found, signing ad-hoc (permissions reset each rebuild)"
	codesign --force --sign - $(APP)
endif

# One-time setup: 'xcrun notarytool store-credentials yapping' with an
# app-specific password. Ticket is stapled so Gatekeeper passes offline.
notarize: sign
	ditto -c -k --keepParent $(APP) .build/Yapping-notarize.zip
	xcrun notarytool submit .build/Yapping-notarize.zip \
		--keychain-profile yapping --wait
	xcrun stapler staple $(APP)
	rm -f .build/Yapping-notarize.zip

install: sign
	pkill -x yapping || true
	sleep 1
	rm -rf /Applications/Yapping.app
	ditto $(APP) /Applications/Yapping.app
	open -ga /Applications/Yapping.app
	@echo "installed and launched: /Applications/Yapping.app"

run: sign
	pkill -x yapping || true
	open -ga $(APP)

clean:
	rm -rf .build

# Cut a GitHub release: make release NOTES=notes.md (version from Info.plist)
VERSION := $(shell /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Support/Info.plist)

# Stable asset name so releases/latest/download/Yapping.dmg always works
dmg: sign
	bash scripts/make-dmg.sh .build/Yapping.dmg

# Notarize before packaging so the dmg and zip carry the stapled app.
# (Not via the dmg target: its sign dependency re-bundles, wiping the staple.)
# Needs both the Developer ID cert and stored notarytool credentials
# (xcrun notarytool store-credentials yapping); missing either skips the step.
# Ask notarytool itself rather than guessing at keychain service names:
# a probe that silently answers "no" ships unnotarized releases.
NOTARY_READY := $(shell xcrun notarytool history --keychain-profile yapping >/dev/null 2>&1 && echo yes)

release: sign
ifneq (,$(findstring Developer ID,$(IDENTITY)))
ifeq ($(NOTARY_READY),yes)
	$(MAKE) notarize
else
	@echo "no notarytool credentials (run: xcrun notarytool store-credentials yapping); releasing without notarization"
endif
else
	@echo "no Developer ID identity; releasing without notarization"
endif
	bash scripts/make-dmg.sh .build/Yapping.dmg
	ditto -c -k --keepParent $(APP) .build/Yapping-v$(VERSION).zip
	git tag v$(VERSION)
	git push origin v$(VERSION)
	gh release create v$(VERSION) \
		.build/Yapping.dmg \
		.build/Yapping-v$(VERSION).zip \
		--title "Yapping v$(VERSION)" $(if $(NOTES),--notes-file $(NOTES),--generate-notes)
