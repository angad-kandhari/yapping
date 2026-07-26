#!/bin/bash
# Build a drag-to-install DMG: Yapping.app + /Applications symlink over the
# branded background. Finder layout via AppleScript; if automation
# permission is missing the DMG is still produced, just with default layout.
set -euo pipefail

APP=".build/Yapping.app"
OUT="${1:?usage: make-dmg.sh <output.dmg>}"
VOL="yapping"

STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
mkdir "$STAGE/.background"
cp icon-pack/dmg-background.png "$STAGE/.background/background.png"

RWDIR=$(mktemp -d)
RW="$RWDIR/rw.dmg"
hdiutil create -volname "$VOL" -srcfolder "$STAGE" -ov -format UDRW "$RW" -quiet
MOUNT=$(hdiutil attach "$RW" -readwrite -noverify -noautoopen | grep -o '/Volumes/.*' | head -1)

osascript <<APPLESCRIPT || echo "warning: Finder layout skipped (automation permission?)"
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 520}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 112
    set background picture of viewOptions to file ".background:background.png"
    set position of item "Yapping.app" of container window to {165, 210}
    set position of item "Applications" of container window to {495, 210}
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT

sync
hdiutil detach "$MOUNT" -quiet
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$OUT" -ov -quiet
IDENTITY=$(security find-identity -v -p codesigning | grep -o '"Apple Development[^"]*"' | head -1 | tr -d '"')
if [ -n "$IDENTITY" ]; then
  codesign --force --sign "$IDENTITY" "$OUT"
else
  codesign --force --sign - "$OUT"
fi
rm -rf "$STAGE" "$RWDIR"
echo "dmg ready: $OUT"
