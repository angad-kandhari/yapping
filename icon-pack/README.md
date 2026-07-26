# yapping icon pack

Extract this folder into the repo (e.g. ~/Projects/dictate-swift/icon-pack, or merge into Support/).

## App icon
- AppIcon.iconset/ — 10 PNGs, 16-1024 px
- Build the .icns:
      iconutil -c icns yapping-pack/AppIcon.iconset -o Support/AppIcon.icns
- Reference it: copy AppIcon.icns into the bundle's Resources in the Makefile and add to Support/Info.plist:
      <key>CFBundleIconFile</key><string>AppIcon</string>
- yapping-icon.svg / yapping-icon-1024.png — master art

## Menu bar (StatusItem.swift)
- menubar/yappingTemplate.png (18 px) + @2x (36 px), black + alpha
- Replace the emoji title:
      let img = NSImage(named: "yappingTemplate")   // or load from bundle path
      img?.isTemplate = true
      item.button?.image = img
  Keep the block-character waveform titles while recording (clear button.image, set title), or leave the glyph static.

## Wordmark
- wordmark/wordmark-dark.png (on dark), wordmark-light.png (on light)
- Type: Geist Bold, lowercase "yapping"
