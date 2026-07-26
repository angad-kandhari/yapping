# dictate icon pack

Extract this folder into the repo (e.g. ~/Projects/dictate-swift/icon-pack, or merge into Support/).

## App icon
- AppIcon.iconset/ — 10 PNGs, 16-1024 px
- Build the .icns:
      iconutil -c icns icon-pack/AppIcon.iconset -o Support/AppIcon.icns
- Reference it: copy AppIcon.icns into the bundle's Resources in the Makefile and add to Support/Info.plist:
      <key>CFBundleIconFile</key><string>AppIcon</string>
- dictate-icon.svg / dictate-icon-1024.png — master art

## Menu bar (StatusItem.swift)
- menubar/dictateTemplate.png (18 px) + @2x (36 px), black + alpha
- Replace the emoji title:
      let img = NSImage(named: "dictateTemplate")   // or load from bundle path
      img?.isTemplate = true
      item.button?.image = img
  Keep the block-character waveform titles while recording (clear button.image, set title), or leave the glyph static.

## Wordmark
- wordmark/wordmark.png (light backgrounds), wordmark-dark.png (dark backgrounds)
