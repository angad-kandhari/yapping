APP      := .build/Yapping.app
BINARY   := .build/arm64-apple-macosx/release/yapping
IDENTITY := $(shell security find-identity -v -p codesigning | grep -o '"Apple Development[^"]*"' | head -1)

.PHONY: build bundle sign install run clean

build:
	swift build -c release --arch arm64

bundle: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(BINARY) $(APP)/Contents/MacOS/yapping
	cp Support/Info.plist $(APP)/Contents/
	cp Support/AppIcon.icns $(APP)/Contents/Resources/

# A stable (non ad-hoc) signature keeps TCC grants valid across rebuilds
sign: bundle
ifneq ($(IDENTITY),)
	codesign --force --sign $(IDENTITY) $(APP)
else
	@echo "no Apple Development identity found, signing ad-hoc (permissions reset each rebuild)"
	codesign --force --sign - $(APP)
endif

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

release: sign dmg
	ditto -c -k --keepParent $(APP) .build/Yapping-v$(VERSION).zip
	git tag v$(VERSION)
	git push origin v$(VERSION)
	gh release create v$(VERSION) \
		.build/Yapping.dmg \
		.build/Yapping-v$(VERSION).zip \
		--title "Yapping v$(VERSION)" $(if $(NOTES),--notes-file $(NOTES),--generate-notes)
