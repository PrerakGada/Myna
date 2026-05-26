# Myna — landing page

A single-page, mobile-first landing page for [Myna](https://github.com/PrerakGada/myna), the native macOS menu-bar text-to-speech app — local-only, signed + notarised, auto-updating via Sparkle, distributed as a DMG + Homebrew Cask.

Built with **Next.js 16**, **React 19**, **Tailwind CSS**, and `next/font` for self-hosted Fraunces + Newsreader + JetBrains Mono. No client-side animation library — everything is CSS keyframes + a tiny IntersectionObserver. Statically generated, deployable to Vercel as-is.

The aesthetic is **Warm Reading Room**: cream paper, ink-black body type, a single teal "myna sheen" accent, and a subtle paper grain overlay. Editorial, not SaaS.

---

## Run locally

```bash
cd site
npm install
npm run dev
# → http://localhost:3000
```

## Build

```bash
npm run build
npm run start
```

Build output is fully static (`/` is prerendered with a 10-minute revalidate matching the GitHub stars cache).

## Deploy to Vercel

```bash
# from inside ./site
npx vercel
# → follow prompts, accept defaults; “site” is the root
```

Or push to GitHub and import the repo in the Vercel dashboard — set **Root Directory** to `site` and accept the auto-detected Next.js settings.

No environment variables are required. The live GitHub star count is fetched server-side via the public GitHub API and cached for 10 minutes.

## Project layout

```
site/
├── app/
│   ├── layout.tsx       fonts, metadata, viewport, grain overlay
│   ├── page.tsx         the whole landing page (sections inline)
│   └── globals.css      Warm Reading Room design tokens
├── components/
│   ├── Nav.tsx                 sticky nav + mobile drawer
│   ├── MynaMark.tsx            hand-drawn myna bird SVG mark
│   ├── GitHubStar.tsx          live ★ count, SSR + revalidate
│   ├── Soundwave.tsx           CSS-animated waveform bars
│   ├── MenubarMockup.tsx       hero visual (menubar + dropdown)
│   ├── SelectionVisual.tsx     feature 01 — browser + chord card
│   ├── ArticleVisual.tsx       feature 02 — messy vs. clean article
│   ├── ClaudeSessionsVisual.tsx feature 03 — session queue
│   ├── ControlVisual.tsx       feature 04 — shortcut table
│   ├── PrivacyVisual.tsx       feature 05 — local-only diagram
│   ├── ArchitectureDiagram.tsx App · Daemon · Voice
│   ├── CopyBlock.tsx           tap-to-copy code blocks
│   ├── FAQ.tsx                 accordion
│   ├── Reveal.tsx              IO-based scroll reveal
│   ├── MobileStickyCTA.tsx     bottom pill on mobile
│   └── Kbd.tsx                 ⌘⌥⇧S key cap renderer
└── public/
    └── favicon.svg
```

## Design notes

- **Typography**: Fraunces (display, variable, optical sizing) + Newsreader (body) + JetBrains Mono (code, eyebrow labels).
- **Colour**: cream paper `#F5EFE2`, warm ink `#1A1714`, single teal accent (`#0F6B5C` / `#0A4F44`), rust `#B65A3C` for inline numerals.
- **Motion**: one orchestrated hero fade-up, soundwaves in the menubar, scroll-reveals via IntersectionObserver. Everything respects `prefers-reduced-motion`.
- **Mobile**: every section was designed at 375px first. Touch targets ≥ 44px. Sticky install pill appears after the hero and tucks above the home indicator. Mobile nav is a backdrop-blur drawer.
- **Performance**: zero third-party runtime libraries beyond React/Next. All visuals are hand-drawn SVG + CSS. Statically generated, no runtime API calls except the cached GitHub stars fetch.

## What's intentionally absent

- No 3D blobs, no purple gradients, no stock illustrations.
- No newsletter capture, no cookie banner, no analytics by default.
- No pricing table — Myna is free.
- No customer logos / fake testimonials.

## License

MIT (same as the parent Myna project).
