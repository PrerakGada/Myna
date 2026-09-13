/* eslint-disable @next/next/no-img-element */
import { Nav } from "@/components/Nav";
import { GitHubStarButton } from "@/components/GitHubStar";
import { MynaMark } from "@/components/MynaMark";
import { StaticWave } from "@/components/Soundwave";
import { Reveal } from "@/components/Reveal";
import { Kbd } from "@/components/Kbd";
import { SelectionVisual } from "@/components/SelectionVisual";
import { ArticleVisual } from "@/components/ArticleVisual";
import { HandsFreeVisual } from "@/components/HandsFreeVisual";
import { ArchitectureDiagram } from "@/components/ArchitectureDiagram";
import { CopyBlock } from "@/components/CopyBlock";
import { FAQ } from "@/components/FAQ";
import { MobileStickyCTA } from "@/components/MobileStickyCTA";
import { HeroScene } from "@/components/HeroScene";
import { DownloadButton, getLatestVersion } from "@/components/DownloadButton";
import { PillMock, PillBar } from "@/components/mac/PillMock";
import { PopoverMock } from "@/components/mac/PopoverMock";
import { InstallerMock } from "@/components/mac/InstallerMock";

const GITHUB_URL = "https://github.com/PrerakGada/Myna";

export default async function Page() {
  const version = await getLatestVersion();

  return (
    <main id="top" className="relative overflow-x-clip">
      <Nav starSlot={<GitHubStarButton compact />} />

      {/* ───────────── HERO ───────────── */}
      <section className="paper-grain pt-28 pb-16 sm:pt-36 sm:pb-24 md:pt-40 md:pb-28">
        <div className="mx-auto max-w-6xl px-5 sm:px-8">
          <div className="mb-7 flex items-center gap-3 animate-fade-in sm:mb-9">
            <span className="h-px w-8 bg-ink/30" />
            <span className="font-mono text-[0.72rem] uppercase tracking-[0.22em] text-ink-muted">
              Free · open source · for Apple Silicon Macs
            </span>
          </div>

          <h1
            className="font-display text-display-xl font-light text-ink balance"
            style={{ animation: "fadeUp 0.9s 0.05s both" }}
          >
            Your eyes are tired.
            <br />
            <span className="italic font-normal text-teal-deep">Your Mac can read.</span>
          </h1>

          <div className="mt-10 grid items-start gap-14 sm:mt-12 md:grid-cols-[minmax(0,0.92fr)_minmax(0,1.08fr)] md:gap-12 lg:gap-16">
            <div className="min-w-0 md:pt-8">
              <p
                className="max-w-[36ch] text-[1.12rem] leading-[1.6] text-ink-soft pretty sm:text-[1.22rem]"
                style={{ animation: "fadeUp 0.9s 0.18s both" }}
              >
                Select text in any app and press <Kbd keys={["cmd", "alt", "shift", "S"]} />. Myna reads it to you in a
                natural voice{" "}
                <span className="text-ink">generated right on your Mac: no cloud speech service, no account, no subscription.</span>
              </p>

              <div className="mt-8 flex flex-col gap-3 sm:flex-row sm:items-center" style={{ animation: "fadeUp 0.9s 0.28s both" }}>
                <DownloadButton />
                <a href="#install" className="btn-ghost">
                  How installing works
                </a>
              </div>
              <p className="mt-4 font-mono text-[0.72rem] tracking-[0.04em] text-ink-muted" style={{ animation: "fadeUp 0.9s 0.34s both" }}>
                {version ? `Version ${version} · ` : ""}macOS 14+ · 4 MB download · voice installs on first launch
              </p>
            </div>

            <div className="min-w-0 md:pt-2" style={{ animation: "fadeUp 0.9s 0.32s both" }}>
              <HeroScene />
            </div>
          </div>
        </div>
      </section>

      {/* ───────────── PROOF STRIP ───────────── */}
      <section className="relative">
        <div className="absolute inset-x-0 top-0 rule-hair" />
        <div className="mx-auto grid max-w-6xl grid-cols-1 gap-6 px-5 py-12 sm:grid-cols-3 sm:px-8 sm:py-14">
          {[
            { k: "Any app", v: "Browsers, PDFs, mail, Slack, terminals: if you can select it, Myna can read it." },
            { k: "On your Mac", v: "Kokoro runs on Apple Silicon through MLX. Your text never goes to a speech service." },
            { k: "Free for good", v: "MIT-licensed source. No account, no usage limits, nothing to upgrade to." },
          ].map((item) => (
            <div key={item.k} className="flex gap-4">
              <span className="mt-2 h-1.5 w-1.5 shrink-0 rounded-full bg-teal" />
              <div>
                <div className="font-display text-[1.3rem] text-ink">{item.k}</div>
                <p className="mt-1 text-[0.98rem] leading-[1.6] text-ink-soft pretty">{item.v}</p>
              </div>
            </div>
          ))}
        </div>
        <div className="absolute inset-x-0 bottom-0 rule-hair" />
      </section>

      {/* ───────────── HOOK ───────────── */}
      <section className="relative py-20 sm:py-28">
        <div className="mx-auto max-w-3xl px-5 sm:px-8">
          <Reveal>
            <p className="font-display text-[1.6rem] leading-[1.22] text-ink balance dropcap sm:text-[2rem] md:text-[2.3rem]">
              Some afternoons the screen turns to gauze. The words you&rsquo;ve read since morning blur into one long ribbon,
              and the prose you still owe the day feels heavier than it should. Myna is for those afternoons{" "}
              <span className="italic text-teal-deep">
                — a small companion in the menu bar that takes the reading off your eyes and gives it back to you as a voice.
              </span>
            </p>
          </Reveal>
        </div>
      </section>

      {/* ───────────── FEATURES ───────────── */}
      <section id="features" className="relative">
        <div className="mx-auto max-w-6xl px-5 sm:px-8">
          <Reveal>
            <div className="mb-6 flex flex-wrap items-end justify-between gap-4 sm:mb-10">
              <div>
                <div className="mb-3 font-mono text-[0.72rem] uppercase tracking-[0.22em] text-ink-muted">
                  No. I · what it does
                </div>
                <h2 className="font-display text-display-lg text-ink balance">
                  Small superpowers,
                  <br />
                  one quiet bird.
                </h2>
              </div>
              <div className="hidden text-ink/30 sm:block">
                <StaticWave bars={36} height={28} className="w-44" />
              </div>
            </div>
          </Reveal>

          <FeatureRow
            number="01"
            eyebrow="Selection"
            title={<>Select. Press. <span className="italic text-teal-deep">Listen.</span></>}
            body={<>
              Highlight text anywhere — a web page, a PDF, an email, a terminal — and press{" "}
              <Kbd keys={["cmd", "alt", "shift", "S"]} />. Myna reads it straight through, from the first word to the last,
              without stalling mid-sentence. Want the gist instead? <Kbd keys={["cmd", "alt", "shift", "A"]} /> has a local
              model summarize it first, if you run Ollama.
            </>}
            visual={<SelectionVisual />}
          />

          <FeatureRow
            number="02"
            eyebrow="Articles"
            title={<>The page, <span className="italic text-teal-deep">read to you.</span></>}
            body={<>
              Open an article in Chrome and press <Kbd keys={["cmd", "alt", "shift", "R"]} />. Myna pulls the piece out of
              the page — no navigation, no cookie banner, no &ldquo;subscribe&rdquo; box read in a calm voice — and reads just
              the writing.
            </>}
            visual={<ArticleVisual />}
            reverse
          />

          <FeatureRow
            number="03"
            eyebrow="The player"
            title={<>A player that <span className="italic text-teal-deep">stays out of the way.</span></>}
            body={<>
              While Myna reads, a slim bar waits at the bottom of your screen. Hover and it opens into a player: scrub, jump
              ten seconds, pause, or speed up to 2× without the chipmunk pitch. Drag it anywhere and it stays there. The
              menu bar holds the rest — your voice, your speed, and the last five things you listened to, one click from a
              replay.
            </>}
            visual={<PlayerVisual />}
          />

          <FeatureRow
            number="04"
            eyebrow="Hands-free"
            title={<>Four fingers, <span className="italic text-teal-deep">or no hands at all.</span></>}
            body={<>
              Turn on trackpad gestures and a four-finger press-and-hold reads your selection, with a soft tone to say it
              heard you; a four-finger double-tap stops. Or drive Myna from Shortcuts, Raycast, Alfred or BetterTouchTool
              with <span className="font-mono text-[0.92em] text-ink">myna://</span> links. Every hotkey can be rebound.
            </>}
            visual={<HandsFreeVisual />}
            reverse
          />
        </div>
      </section>

      {/* ───────────── CLAUDE CODE ───────────── */}
      <section id="claude-code" className="relative mt-20 overflow-hidden bg-ink py-24 text-paper sm:mt-28 sm:py-32">
        <div
          aria-hidden="true"
          className="absolute inset-0"
          style={{ background: "radial-gradient(ellipse 55% 60% at 85% 30%, rgba(63,191,168,0.14), transparent 70%)" }}
        />
        <div className="relative mx-auto grid max-w-6xl items-center gap-14 px-5 sm:px-8 md:grid-cols-[minmax(0,1fr)_minmax(0,1fr)] md:gap-16">
          <Reveal>
            <div className="max-w-[46ch]">
              <div className="mb-3 font-mono text-[0.72rem] uppercase tracking-[0.22em] text-paper/45">
                No. II · for Claude Code
              </div>
              <h2 className="font-display text-display-lg balance">
                Your agents finish.
                <br />
                <span className="italic text-teal-glow">You hear the answer.</span>
              </h2>
              <p className="mt-6 text-[1.05rem] leading-[1.7] text-paper/75 pretty sm:text-[1.1rem]">
                Start a long task, go and read something else, and let the reply come to you. When a Claude Code session
                ends, its answer appears in Myna&rsquo;s player as <em className="text-paper">New output ready</em>. Press
                Play and the whole reply is read in your voice. Run five sessions at once and they still arrive one at a time,
                so nothing talks over anything else.
              </p>
              <ul className="mt-7 space-y-3 text-[1rem] leading-[1.55] text-paper/80">
                {[
                  "One click reads the full reply, not a truncated preview.",
                  "Replies waiting to be heard stay in the menu bar for ten minutes, colour-coded by project.",
                  "Connected during setup if Claude Code is on your Mac. Nothing to configure.",
                ].map((line) => (
                  <li key={line} className="flex gap-3">
                    <span className="mt-[0.6em] h-1.5 w-1.5 shrink-0 rounded-full bg-teal-glow" />
                    <span className="pretty">{line}</span>
                  </li>
                ))}
              </ul>
            </div>
          </Reveal>
          <Reveal delay={100}>
            <div className="relative mx-auto flex max-w-[420px] flex-col items-center gap-6 md:items-end">
              <PopoverMock className="md:mr-10" />
              <PillMock variant="prompt" className="-mt-20 md:-ml-6 md:mr-auto" />
            </div>
          </Reveal>
        </div>
      </section>

      {/* ───────────── WHY LOCAL ───────────── */}
      <section className="relative py-24 sm:py-32">
        <div className="mx-auto max-w-6xl px-5 sm:px-8">
          <Reveal>
            <div className="mb-14 max-w-3xl sm:mb-16">
              <div className="mb-3 font-mono text-[0.72rem] uppercase tracking-[0.22em] text-ink-muted">
                No. III · why local
              </div>
              <h2 className="font-display text-display-lg text-ink balance">
                A voice that lives
                <br />
                <span className="italic text-teal-deep">on your Mac.</span>
              </h2>
            </div>
          </Reveal>

          <div className="grid grid-cols-1 gap-7 md:grid-cols-3 md:gap-10">
            {[
              {
                h: "Private",
                b: "The voice is generated by the Kokoro model on your own Mac, so what you select is never sent to a speech service. No analytics, no telemetry.",
                stat: "no speech API, no tracking",
              },
              {
                h: "Free",
                b: "Cloud voices bill by the character and the month. Myna has nothing to bill: no account, no subscription, no usage limits, MIT-licensed.",
                stat: "$0 · MIT",
              },
              {
                h: "Dependable",
                b: "No API key to expire, no rate limit to hit, no service that changes its voice or shuts down. The model sits on your disk and keeps working.",
                stat: "Kokoro-82M · MLX",
              },
            ].map((c, i) => (
              <Reveal key={c.h} delay={i * 80}>
                <article className="relative h-full rounded-2xl bg-paper-warm p-7 shadow-soft ring-1 ring-ink/8 lift">
                  <div className="mb-4 font-mono text-[0.7rem] uppercase tracking-[0.22em] text-rust">
                    {String(i + 1).padStart(2, "0")}
                  </div>
                  <h3 className="mb-3 font-display text-[1.85rem] tracking-tight text-ink">{c.h}.</h3>
                  <p className="mb-6 text-[1.02rem] leading-[1.65] text-ink-soft pretty">{c.b}</p>
                  <div className="border-t border-ink/8 pt-4 font-mono text-[0.78rem] text-teal-deep numerals-tab">{c.stat}</div>
                </article>
              </Reveal>
            ))}
          </div>
          <Reveal>
            <p className="mt-10 max-w-3xl text-[0.95rem] leading-[1.65] text-ink-muted pretty">
              In the interest of plain dealing: Myna does use the network to download its voice during setup, to check
              GitHub for updates, and to fetch an article&rsquo;s page when you ask it to read one. Summaries go to Ollama,
              which also runs on your Mac.
            </p>
          </Reveal>
        </div>
      </section>

      {/* ───────────── INSTALL ───────────── */}
      <section id="install" className="relative bg-ink py-24 text-paper sm:py-32">
        <div className="mx-auto max-w-6xl px-5 sm:px-8">
          <Reveal>
            <div className="mb-14 max-w-3xl sm:mb-16">
              <div className="mb-3 font-mono text-[0.72rem] uppercase tracking-[0.22em] text-paper/45">
                No. IV · install
              </div>
              <h2 className="font-display text-display-lg balance">
                Download. Drag.
                <br />
                <span className="italic text-teal-glow">Open.</span>
              </h2>
              <p className="mt-5 max-w-[54ch] text-[1.05rem] leading-[1.65] text-paper/70 pretty">
                One small download. The first time you open Myna, it installs its own voice — no Terminal, no Homebrew, no
                admin password — and then it lives in your menu bar.
              </p>
            </div>
          </Reveal>

          <div className="grid gap-10 lg:grid-cols-3 lg:gap-8">
            <Reveal className="min-w-0">
              <InstallStep n="1" title="Download Myna">
                <p>
                  A signed, Apple-notarized disk image of about 4&nbsp;MB.
                </p>
                <div className="mt-6">
                  <DownloadButton className="!bg-paper !text-ink" />
                </div>
                <p className="mt-4 font-mono text-[0.72rem] text-paper/45">
                  {version ? `Version ${version} · ` : ""}
                  <a href={`${GITHUB_URL}/releases`} className="ink-underline hover:text-paper" target="_blank" rel="noopener noreferrer">
                    all releases
                  </a>
                </p>
              </InstallStep>
            </Reveal>
            <Reveal delay={80} className="min-w-0">
              <InstallStep n="2" title="Drag it into Applications">
                <p>Open the disk image and drag the bird onto the Applications folder.</p>
                <img
                  src="/dmg-window.png"
                  alt="The Myna disk image window: drag Myna into Applications"
                  width={660}
                  height={448}
                  className="mt-6 w-full rounded-[12px] shadow-[0_30px_60px_-24px_rgba(0,0,0,0.8)] ring-1 ring-white/10"
                />
              </InstallStep>
            </Reveal>
            <Reveal delay={160} className="min-w-0">
              <InstallStep n="3" title="Open it — it sets up its voice">
                <p>
                  About 1&nbsp;GB, a few minutes on a good connection. Then allow Accessibility, select something, and press{" "}
                  <span className="font-mono text-paper">⌘⌥⇧S</span>.
                </p>
                <InstallerMock className="mt-6" />
              </InstallStep>
            </Reveal>
          </div>

          <Reveal>
            <div className="mt-14 grid gap-4 sm:grid-cols-3">
              <Detail label="Chip" value="Apple Silicon · M1 or later" />
              <Detail label="System" value="macOS 14 Sonoma or later" />
              <Detail label="Space" value="About 1 GB for the voice" />
            </div>
          </Reveal>

          <Reveal>
            <div className="mt-14 grid gap-8 md:grid-cols-2">
              <div>
                <h3 className="font-display text-[1.5rem]">Prefer Homebrew?</h3>
                <p className="mt-2 text-[0.98rem] leading-[1.65] text-paper/65 pretty">
                  The cask installs the app plus its background service, and adds a <span className="font-mono">myna</span>{" "}
                  command for reading from the terminal. Open Myna once afterwards to finish setting up the voice.
                </p>
                <CopyBlock
                  className="mt-5"
                  lines={[
                    { prompt: true, text: "brew tap prerakgada/tap" },
                    { prompt: true, text: "brew trust prerakgada/tap" },
                    { prompt: true, text: "brew install --cask prerakgada/tap/myna" },
                  ]}
                />
              </div>
              <div>
                <h3 className="font-display text-[1.5rem]">Want summaries?</h3>
                <p className="mt-2 text-[0.98rem] leading-[1.65] text-paper/65 pretty">
                  The summary shortcut hands your selection to a small local model through Ollama. Skip this if you only want
                  Myna to read.
                </p>
                <CopyBlock
                  className="mt-5"
                  lines={[
                    { prompt: true, text: "brew install ollama" },
                    { prompt: true, text: "ollama pull qwen3.5:4b" },
                  ]}
                />
              </div>
            </div>
          </Reveal>
        </div>
      </section>

      {/* ───────────── SHORTCUTS ───────────── */}
      <section className="relative py-24 sm:py-32">
        <div className="mx-auto max-w-4xl px-5 sm:px-8">
          <Reveal>
            <div className="mb-10 sm:mb-14">
              <div className="mb-3 font-mono text-[0.72rem] uppercase tracking-[0.22em] text-ink-muted">
                Default shortcuts · all rebindable
              </div>
              <h2 className="font-display text-[2rem] text-ink balance sm:text-display-md">
                Five keys. <span className="italic text-teal-deep">No clashes.</span>
              </h2>
              <p className="mt-3 max-w-[54ch] text-[1rem] leading-[1.65] text-ink-soft pretty">
                They all start with <Kbd keys={["cmd", "alt", "shift"]} />, so they stay clear of the shortcuts you already
                use. Change any of them in Settings → Hotkeys.
              </p>
            </div>
          </Reveal>

          <Reveal delay={80}>
            <div className="overflow-hidden rounded-2xl bg-paper-warm shadow-soft ring-1 ring-ink/8">
              <ul className="divide-y divide-ink/8">
                {[
                  { name: "Read the selection", keys: ["cmd", "alt", "shift", "S"] },
                  { name: "Summarize the selection", note: "needs Ollama", keys: ["cmd", "alt", "shift", "A"] },
                  { name: "Read the Chrome article", keys: ["cmd", "alt", "shift", "R"] },
                  { name: "Pause / resume", keys: ["cmd", "alt", "shift", "space"] },
                  { name: "Stop", keys: ["cmd", "alt", "shift", "."] },
                ].map((r) => (
                  <li key={r.name} className="flex items-center justify-between gap-4 px-5 py-4 transition-colors hover:bg-paper-deep/40 sm:px-7 sm:py-5">
                    <span className="text-[1.02rem] text-ink">
                      {r.name}
                      {r.note && <span className="ml-2 font-mono text-[0.7rem] text-ink-muted">{r.note}</span>}
                    </span>
                    <Kbd keys={r.keys} />
                  </li>
                ))}
              </ul>
            </div>
          </Reveal>
        </div>
      </section>

      {/* ───────────── HOW IT WORKS ───────────── */}
      <section id="how" className="relative bg-paper-deep/50 py-20 sm:py-28">
        <div className="absolute inset-x-0 top-0 rule-hair" />
        <div className="absolute inset-x-0 bottom-0 rule-hair" />
        <div className="mx-auto max-w-6xl px-5 sm:px-8">
          <Reveal>
            <div className="mb-14 max-w-3xl sm:mb-20">
              <div className="mb-3 font-mono text-[0.72rem] uppercase tracking-[0.22em] text-ink-muted">
                No. V · how it works
              </div>
              <h2 className="font-display text-display-lg text-ink balance">Three layers, quietly stacked.</h2>
              <p className="mt-5 max-w-[52ch] text-[1.05rem] leading-[1.65] text-ink-soft pretty">
                Each part does one job. The app is what you touch, the daemon decides what to say and in what order, and the
                voice speaks. All three run on your Mac and talk to each other over its loopback address.
              </p>
            </div>
          </Reveal>
          <Reveal>
            <ArchitectureDiagram />
          </Reveal>
        </div>
      </section>

      {/* ───────────── FAQ ───────────── */}
      <section id="faq" className="relative py-24 sm:py-32">
        <div className="mx-auto max-w-4xl px-5 sm:px-8">
          <Reveal>
            <div className="mb-10 sm:mb-14">
              <div className="mb-3 font-mono text-[0.72rem] uppercase tracking-[0.22em] text-ink-muted">
                No. VI · questions
              </div>
              <h2 className="font-display text-display-lg text-ink balance">Answered plainly.</h2>
            </div>
          </Reveal>
          <Reveal delay={80}>
            <FAQ />
          </Reveal>
        </div>
      </section>

      {/* ───────────── CLOSING ───────────── */}
      <section className="relative bg-paper-deep/40 py-24 sm:py-32">
        <div className="absolute inset-x-0 top-0 rule-hair" />
        <div className="mx-auto max-w-4xl px-5 text-center sm:px-8">
          <Reveal>
            <div className="mb-6 flex justify-center">
              <img src="/app-icon.png" alt="" width={96} height={96} className="h-24 w-24" />
            </div>
            <h2 className="font-display text-display-md italic text-ink balance">
              Made for people who&rsquo;d
              <br className="hidden sm:inline" /> rather listen.
            </h2>
            <div className="mt-9 flex flex-col items-center justify-center gap-3 sm:flex-row">
              <DownloadButton />
              <a href={GITHUB_URL} target="_blank" rel="noopener noreferrer" className="btn-ghost">
                Star on GitHub
              </a>
            </div>
          </Reveal>
        </div>
      </section>

      <footer className="border-t border-ink/10 bg-paper-warm/50 py-10 sm:py-14">
        <div className="mx-auto flex max-w-6xl flex-col items-center justify-between gap-5 px-5 sm:flex-row sm:px-8">
          <div className="flex items-center gap-2.5">
            <MynaMark size={22} />
            <span className="font-display text-[1.05rem]">Myna</span>
            <span className="ml-2 font-mono text-[0.72rem] text-ink-muted">
              {version ? `v${version} · ` : ""}MIT
            </span>
          </div>
          <nav className="flex flex-wrap items-center justify-center gap-5 font-mono text-[0.78rem] text-ink-muted" aria-label="Footer">
            <a href="/brand/Myna-Brand-Assets.zip" download className="transition-colors hover:text-ink">brand assets</a>
            <a href={GITHUB_URL} target="_blank" rel="noopener noreferrer" className="transition-colors hover:text-ink">github</a>
            <a href={`${GITHUB_URL}/releases`} target="_blank" rel="noopener noreferrer" className="transition-colors hover:text-ink">releases</a>
            <a href={`${GITHUB_URL}/issues`} target="_blank" rel="noopener noreferrer" className="transition-colors hover:text-ink">issues</a>
            <a href={`${GITHUB_URL}/blob/main/SECURITY.md`} target="_blank" rel="noopener noreferrer" className="transition-colors hover:text-ink">security</a>
          </nav>
          <div className="font-display text-[0.95rem] italic text-ink-muted">
            made by{" "}
            <a href="https://github.com/PrerakGada" target="_blank" rel="noopener noreferrer" className="ink-underline hover:text-ink">
              Prerak Gada
            </a>
          </div>
        </div>
      </footer>

      <MobileStickyCTA />
    </main>
  );
}

/* ── helpers ──────────────────────────────────────────────────────── */

function FeatureRow({
  number,
  eyebrow,
  title,
  body,
  visual,
  reverse,
}: {
  number: string;
  eyebrow: string;
  title: React.ReactNode;
  body: React.ReactNode;
  visual: React.ReactNode;
  reverse?: boolean;
}) {
  return (
    <Reveal>
      <div className="relative grid grid-cols-1 items-center gap-10 py-14 md:grid-cols-[minmax(0,1fr)_minmax(0,1fr)] md:gap-16 md:py-20">
        <div className={`min-w-0 max-w-[44ch] ${reverse ? "md:order-2" : ""}`}>
          <div className="mb-5 flex items-center gap-3">
            <span className="font-mono text-[0.72rem] uppercase tracking-[0.22em] text-rust numerals-tab">{number}</span>
            <span className="h-px w-8 bg-ink/20" />
            <span className="font-mono text-[0.72rem] uppercase tracking-[0.22em] text-ink-muted">{eyebrow}</span>
          </div>
          <h3 className="font-display text-[2rem] leading-[1.04] tracking-tight text-ink pretty sm:text-[2.4rem] md:text-[2.8rem]">
            {title}
          </h3>
          <p className="mt-5 text-[1.05rem] leading-[1.65] text-ink-soft pretty sm:text-[1.1rem]">{body}</p>
        </div>
        <div className={`min-w-0 ${reverse ? "md:order-1" : ""}`}>{visual}</div>
      </div>
    </Reveal>
  );
}

function PlayerVisual() {
  return (
    <div className="relative">
      <div
        className="relative overflow-hidden rounded-2xl px-4 pb-8 pt-10 shadow-soft ring-1 ring-ink/10 sm:px-8"
        style={{ background: "linear-gradient(160deg, #EFE6D2 0%, #E3D7BF 100%)" }}
      >
        <div className="mb-6 flex items-center justify-center gap-3">
          <span className="hidden font-mono text-[0.68rem] uppercase tracking-[0.18em] text-ink-muted sm:inline">while it reads</span>
          <PillBar />
          <span className="hidden font-mono text-[0.68rem] uppercase tracking-[0.18em] text-ink-muted sm:inline">hover to open ↓</span>
        </div>
        <div className="flex justify-center">
          <PillMock headline="Designing for the ear: why long sentences need air" />
        </div>
        <div className="absolute inset-x-0 bottom-0 h-3 bg-gradient-to-t from-ink/10 to-transparent" aria-hidden="true" />
      </div>
    </div>
  );
}

function InstallStep({ n, title, children }: { n: string; title: string; children: React.ReactNode }) {
  return (
    <div className="flex h-full flex-col">
      <div className="flex items-center gap-3">
        <span className="inline-flex h-8 w-8 items-center justify-center rounded-full bg-paper/10 font-mono text-[0.85rem] text-teal-glow ring-1 ring-paper/15">
          {n}
        </span>
        <h3 className="font-display text-[1.45rem] leading-tight">{title}</h3>
      </div>
      <div className="mt-3 text-[0.98rem] leading-[1.65] text-paper/70 pretty">{children}</div>
    </div>
  );
}

function Detail({ label, value }: { label: string; value: string }) {
  return (
    <div className="rounded-xl bg-paper/[0.04] p-5 ring-1 ring-paper/10">
      <div className="mb-1.5 font-mono text-[0.7rem] uppercase tracking-[0.22em] text-paper/45">{label}</div>
      <div className="font-display text-[1.15rem] text-paper">{value}</div>
    </div>
  );
}
