APP      := .build/Dictate.app
BINARY   := .build/arm64-apple-macosx/release/dictate
IDENTITY := $(shell security find-identity -v -p codesigning | grep -o '"Apple Development[^"]*"' | head -1)

.PHONY: build bundle sign install run clean

build:
	swift build -c release --arch arm64

bundle: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(BINARY) $(APP)/Contents/MacOS/dictate
	cp Support/Info.plist $(APP)/Contents/
	cp Support/AppIcon.icns $(APP)/Contents/Resources/
	cp icon-pack/menubar/dictateTemplate.png icon-pack/menubar/dictateTemplate@2x.png $(APP)/Contents/Resources/

# A stable (non ad-hoc) signature keeps TCC grants valid across rebuilds
sign: bundle
ifneq ($(IDENTITY),)
	codesign --force --sign $(IDENTITY) $(APP)
else
	@echo "no Apple Development identity found, signing ad-hoc (permissions reset each rebuild)"
	codesign --force --sign - $(APP)
endif

install: sign
	pkill -x dictate || true
	rm -rf /Applications/Dictate.app
	ditto $(APP) /Applications/Dictate.app
	open -ga /Applications/Dictate.app
	@echo "installed and launched: /Applications/Dictate.app"

run: sign
	pkill -x dictate || true
	open -ga $(APP)

clean:
	rm -rf .build
