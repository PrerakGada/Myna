# Landing-page brand deployment — 13 September 2026

Published with the user's explicit deployment request to the existing Vercel project `engaze/myna`.

- Canonical URL: https://myna.prerakgada.in
- Production deployment: https://myna-afufz1icb-engaze.vercel.app
- Deployment ID: `dpl_4JDG6DDh22t2kNqwunMuXKGX6NP7`
- Vercel result: `READY`, production domain aliased successfully.
- Previous production: https://myna-73gbv06nx-engaze.vercel.app (`dpl_2yWLYam21UbJVpwBUXvfWL1qR3i8`).
- Source: validated site-only snapshot of `feat/approved-myna-brand`. Native app code, local environment files and build outputs were excluded from the upload. No Git commit or push was performed.
- Next.js updated to 16.3.5 and compatible dependency fixes applied before publishing. `npm audit --omit=dev` reports zero vulnerabilities. The legacy local tracing tool still has development-only advisories.
- Local and Vercel builds passed; the Vercel log confirms Next 16.3.5 and the 21-file brand check.
- All 21 public branding assets returned HTTP 200 and SHA-256 matched the approved local deployment manifest, including the clay app icon, both favicons, Apple icon, templates, bordered logo, installer illustration, social cards and brand ZIP.
- Home page returned HTTP 200; the brand ZIP link is present. `/download` still returns 307 to the existing GitHub latest-release DMG.
- Live browser review: new clay logo loaded on every app-icon surface and no horizontal overflow at 1440px. Screenshot: `verification/production-home.png`. Exact HTTP/hash evidence: `verification/production-assets.json`.

This publishes the landing page and branding assets, not a new native DMG or GitHub release. The separately installed local Myna app remains the signed build described in `VERIFICATION.md`.
