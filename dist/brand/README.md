# Myna brand assets

Selected on 13 September 2026: the parked **full-bird soft-clay icon**. The half-bird/portrait crops are not selected. Preserve the stationary happy singing posture, medium body, joined raised wings, closed curved eye, short downward tail, tiny feet and absence of a perch.

`sources/myna-clay-approved.png` is the untouched selected artwork. Its SHA-256 is recorded in `manifest.json`. The app icon keeps its original colour and material; the outline, filled and bordered companions are derived artwork for other scales and surfaces.

## Use

- `exports/myna-app-icon.png`, `.svg`, `.webp`, `Myna.icns`, `Myna.iconset/`, `Myna.ico`: app icon and packaging. The macOS files contain the selected rounded tile and transparent outer corners; do not apply another mask or padding.
- `exports/myna-outline.svg`: idle menu-bar glyph and lightweight monochrome use.
- `exports/myna-outline-small.svg`: optically strengthened outline used by native menu-bar assets and 16–32px PNG exports.
- `exports/myna-filled.svg`: speaking/player glyph and small monochrome use. Matching white SVGs and PNGs support dark surfaces; native images use template rendering.
- `exports/myna-bordered.png`, `.svg`, `.webp`: flat apricot/coral companion with a plum contour.
- `exports/png/`: image sizes from 16px to 1024px, including native 18px glyphs.
- `exports/mobile/`: square unmasked art for web/mobile use. This pack does not add an iOS app to Myna.
- `exports/myna-social-card.*`: social sharing artwork.
- `exports/preview.html`: actual-size light/dark icon review.

Outline and filled SVGs are genuine traced vector paths. Colour/clay SVGs preserve raster artwork in SVG containers; the bordered version uses a vector clipping contour to remove its source matte. They are not editable colour vector masters. The source images stay in this repository so regeneration does not depend on the workspace or image-generation tools.

## Regenerate

```sh
cd site
npm ci
npm run brand:build
npm run brand:check
npm run build
```

`dist/brand/render-icon.sh` remains the familiar entry point for regenerating the full asset set. It now uses the local exporter rather than launching a separate headless browser. `site/design/render-og.sh` regenerates the same set, including both social-image routes. Native asset catalogs are committed inputs for Xcode and do not run image generation during a release build.

The native app uses the clay image in onboarding and the popover header; template assets serve idle/speaking menu states and the player badge. Processing, pause and error retain their existing system status symbols and accessibility labels. No continuous animation is added. The app stays a menu-bar app; no Dock presence is forced.

The site uses the clay icon in navigation, footer, installation and closing sections, matching glyphs in its UI mockups, bordered artwork for favicons, and the updated social image. The installer illustration at `/dmg-window.png` also uses the new artwork; it is a branding mockup, not evidence of a newly published/notarized DMG. A checked ZIP is provided at `/brand/Myna-Brand-Assets.zip`.
