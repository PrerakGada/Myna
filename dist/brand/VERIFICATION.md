# Myna brand integration — 13 September 2026

Selected source: full-bird soft-clay icon, SHA-256 `03aeb6548bf3670758a5bee9f5a443b4e261aeb34008669b57060854cbb47d33`.

## Completed

- Original artwork preserved in `sources/myna-clay-approved.png`.
- Clay app icon, bordered colour companion, genuine vector outline/filled templates, inverse white variants, small-size optical outline, PNG/WebP/JPEG/SVG/ICO/ICNS exports, native asset catalogs and website copies generated locally.
- Installed `/Applications/Myna.app` updated from 0.4.7 to 0.5.1 with the new branding. Local build is arm64, signed with the same MIND WEALTH Developer ID / team RC63N3VU27 and bundle ID `dev.myna.app`.
- Backup: `/Users/nimbus/.local/share/myna/brand-backups/2026-09-13-1789242089784/Myna.app`. Existing user settings, voice installation and daemon data were not moved or reset.
- macOS `NSWorkspace.icon(forFile:)` returned the new clay icon for the installed app; captured in `verification/installed-finder-icon.png`.
- Installed asset catalog is byte-identical to the verified exported build. App process is running; existing voice daemon responds with `state: idle`, `engine_up: true` after installation.
- Native archive succeeded through the existing `dist/build.sh`; existing signing script completed and `codesign --verify --deep --strict` passed, including nested helpers.
- 20 focused XCTest checks passed: 17 existing state-mapping tests and 3 native brand tests. Compiled resources load, templates retain alpha and template rendering, outline and filled have different ink coverage, and all five `BirdIconView` states render at 40×36 Retina pixels. Native render captures are in `verification/myna-native-*.png`.
- Browser review at 1440px and 390px: new icon renders in navigation, popover mockup, installer mockup, closing section and footer; no horizontal overflow. UI mockups use the same filled glyph as the app.
- Favicon SVG/ICO, Apple touch icon, outline/filled assets, installer illustration, social images and brand ZIP are included in deployment checks. Normal site builds verify their hashes before Next.js runs.
- Website build and TypeScript check passed. ZIP integrity checked with `unzip -tq`.
- The small outline was initially too faint; only its small-size optical version was strengthened. The original clay master was unchanged.
- One remaining old bird inside the installer screenshot was replaced in both the large app icon and tiny Finder title-bar icon.

## Boundaries

- Local installation is a Developer-ID-signed development build, not a new notarized public release. Gatekeeper's assessment identifies it as unnotarized; no quarantine or security controls were disabled. It launches normally as a locally built app.
- At the local integration checkpoint, no public DMG, GitHub release, commit, push or website deployment had been performed. The landing page was subsequently published on the user's request; see `DEPLOYMENT.md`. Native public-release status is unchanged.
- No clean-machine installer or fresh voice download was exercised. The existing voice stack stayed in place. Native icon/state tests do not claim a new end-to-end speech-engine validation.
- Direct screen capture was unavailable (`could not create image from rect`); native ImageRenderer output and the installed Finder/IconServices rendition were used for icon verification.
- Colour/clay SVGs embed raster artwork. Outline and filled SVGs are traced paths. The installer screenshot is a branding illustration, not a screenshot of a newly released DMG.
- The initial dependency audit flagged the old Next 16.2.6 runtime and tracing-tool development dependencies. Before website deployment, Next was updated to 16.3.5 and compatible fixes applied; the production dependency audit is now clear. Legacy tracing-tool development advisories remain. The exporter processes only repository-local source artwork.
