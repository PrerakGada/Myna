import { Nav } from "@/components/Nav";
import { GitHubStarButton } from "@/components/GitHubStar";
import { MynaMark } from "@/components/MynaMark";
import { Soundwave, StaticWave } from "@/components/Soundwave";
import { MenubarMockup } from "@/components/MenubarMockup";
import { Reveal } from "@/components/Reveal";
import { Kbd } from "@/components/Kbd";
import { SelectionVisual } from "@/components/SelectionVisual";
import { ArticleVisual } from "@/components/ArticleVisual";
import { ClaudeSessionsVisual } from "@/components/ClaudeSessionsVisual";
import { ControlVisual } from "@/components/ControlVisual";
import { PrivacyVisual } from "@/components/PrivacyVisual";
import { ArchitectureDiagram } from "@/components/ArchitectureDiagram";
import { CopyBlock } from "@/components/CopyBlock";
import { FAQ } from "@/components/FAQ";

const GITHUB_URL = "https://github.com/PrerakGada/myna";

export default function Page() {
  return (
    <main id="top" className="relative overflow-x-clip">
      <Nav starSlot={<GitHubStarButton compact />} />

      {/* ───────────── HERO ───────────── */}
      <section className="paper-grain pt-28 pb-16 sm:pt-36 sm:pb-24 md:pt-44 md:pb-28">
        <div className="mx-auto max-w-6xl px-5 sm:px-8">
          {/* tiny eyebrow */}
          <div className="flex items-center gap-3 mb-7 sm:mb-10 animate-fade-in">
            <span className="h-px w-8 bg-ink/30" />
            <span className="font-mono text-[0.72rem] uppercase tracking-[0.22em] text-ink-muted">
              myna · native for macOS Ventura+
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

          <div className="mt-8 sm:mt-10 grid gap-12 md:grid-cols-[minmax(0,1.05fr)_minmax(0,1fr)] md:gap-14 lg:gap-16 items-start">
            <div style={{ animation: "fadeUp 0.9s 0.18s both" }} className="min-w-0">
              <p className="text-[1.12rem] sm:text-[1.22rem] leading-[1.6] text-ink-soft max-w-[34ch] pretty">
                Myna lives in your menu bar and reads any selection, any article, or any finished
                Claude Code session aloud with a single hotkey.{" "}
                <span className="text-ink">Everything happens on your Mac. Nothing ever leaves it.</span>
              </p>

              <div className="mt-7 flex flex-col sm:flex-row gap-3 sm:gap-3.5">
                <a href="#install" className="btn-primary">
                  <span>Install Myna</span>
                  <svg width="14" height="14" viewBox="0 0 14 14" fill="none" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" aria-hidden="true">
                    <path d="M3 7h8M8 4l3 3-3 3"/>
                  </svg>
                </a>
                <a href={GITHUB_URL} target="_blank" rel="noopener noreferrer" className="btn-ghost">
                  Read the source
                </a>
              </div>

              <ul className="mt-7 sm:mt-9 flex flex-wrap gap-x-5 gap-y-2.5 font-mono text-[0.72rem] uppercase tracking-[0.16em] text-ink-muted">
                {["100% local", "signed & notarised", "auto-updating", "MIT licensed"].map((t, i) => (
                  <li key={t} className="flex items-center gap-2">
                    <span className="inline-block h-1 w-1 rounded-full bg-teal" />
                    <span>{t}</span>
                    {i < 3 && <span aria-hidden="true" className="text-ink/20 ml-3 hidden sm:inline">·</span>}
                  </li>
                ))}
              </ul>
            </div>

            <div style={{ animation: "fadeUp 0.9s 0.32s both" }} className="md:pt-2 min-w-0">
              <MenubarMockup />
            </div>
          </div>
        </div>
      </section>

      {/* ───────────── HOOK ───────────── */}
      <section className="relative py-20 sm:py-28 md:py-36">
        <div className="absolute inset-x-0 top-0 rule-hair"/>
        <div className="mx-auto max-w-3xl px-5 sm:px-8">
          <Reveal>
            <p className="font-display text-[1.6rem] sm:text-[2rem] md:text-[2.4rem] leading-[1.22] text-ink balance dropcap">
              Some afternoons the screen turns to gauze. The words you've read since morning blur
              into one long ribbon, and the prose you still owe the day feels heavier than it should.
              Myna is for those afternoons{" "}
              <span className="text-teal-deep italic">— a small companion in the menu bar that takes the reading off your shoulders and gives it back to you as a voice.</span>
            </p>
          </Reveal>
        </div>
      </section>

      {/* ───────────── FEATURES ───────────── */}
      <section id="features" className="relative">
        <div className="mx-auto max-w-6xl px-5 sm:px-8">
          <Reveal>
            <div className="mb-14 sm:mb-20 flex items-end justify-between flex-wrap gap-4">
              <div>
                <div className="font-mono text-[0.72rem] uppercase tracking-[0.22em] text-ink-muted mb-3">
                  No. I · what it does
                </div>
                <h2 className="font-display text-display-lg text-ink balance">
                  Five small superpowers,<br/>one quiet bird.
                </h2>
              </div>
              <div className="text-ink/30 hidden sm:block">
                <StaticWave bars={36} height={28} className="w-44"/>
              </div>
            </div>
          </Reveal>

          {/* Feature 1: Selection */}
          <FeatureRow
            number="01"
            eyebrow="Selection"
            title={<>Select. Press. <span className="italic text-teal-deep">Listen.</span></>}
            body={<>
              Highlight any text anywhere on your Mac and press <Kbd keys={["cmd","alt","shift","S"]}/>. A warm, MLX-rendered
              voice picks it up midstream and reads it back to you. Need the gist instead of the whole essay?{" "}
              <Kbd keys={["cmd","alt","shift","A"]}/> hands the selection to a local Qwen model and speaks a summary —
              in your own room, on your own silicon.
            </>}
            visual={<SelectionVisual />}
          />

          {/* Feature 2: Web */}
          <FeatureRow
            number="02"
            eyebrow="The Web"
            title={<>The page, <span className="italic text-teal-deep">read to you.</span></>}
            body={<>
              Open an article in Chrome, hit <Kbd keys={["cmd","alt","shift","R"]}/>, and Myna pulls the main body
              out of the page and starts reading. No sidebar clutter, no cookie banners, no advertising voiceover.
              Just the piece, the way it was meant to land.
            </>}
            visual={<ArticleVisual />}
            reverse
          />

          {/* Feature 3: Claude Code (the dev flex) */}
          <FeatureRow
            number="03"
            eyebrow="Claude Code"
            title={<>Five sessions finish.<br/><span className="italic text-teal-deep">One voice at a time.</span></>}
            body={<>
              If you run parallel Claude Code sessions, you know the chaos of them all finishing at once. Myna
              quiets that. As each session completes, it whispers itself into the menu bar and{" "}
              <em>waits</em>. You click the one you want to hear. The others stand by, patient, until you're
              ready. No talking over each other. No missed answers buried in noise.
            </>}
            visual={<ClaudeSessionsVisual />}
            accent
          />

          {/* Feature 4: Control */}
          <FeatureRow
            number="04"
            eyebrow="Control"
            title={<>Pause, resume, <span className="italic text-teal-deep">rebind</span>, repeat.</>}
            body={<>
              Real audio, not <span className="font-mono text-[0.92em] text-ink">afplay</span>: AVAudioEngine drives
              playback, so speed changes don't pitch-shift and you can scrub or jump ±15s mid-sentence. A native
              Settings panel rebinds every shortcut, picks the voice, and points the daemon. And{" "}
              <span className="font-mono text-[0.92em] text-ink">myna://</span> URLs let BetterTouchTool,
              Shortcuts, or Alfred drive Myna without simulating a keystroke.
            </>}
            visual={<ControlVisual />}
            reverse
          />

          {/* Feature 5: Private */}
          <FeatureRow
            number="05"
            eyebrow="Private"
            title={<>Local by design, <span className="italic text-teal-deep">free by principle.</span></>}
            body={<>
              The voice model (Kokoro, <span className="font-mono text-[0.92em] text-ink">af_heart</span>) runs on
              your machine. The summariser (Qwen 3.5 4B via Ollama) runs on your machine. No API key, no usage
              meter, no telemetry. MIT-licensed and open at{" "}
              <a href={GITHUB_URL} className="text-teal-deep ink-underline hover:text-teal" target="_blank" rel="noopener noreferrer">
                github.com/PrerakGada/myna
              </a>. What you read stays with you, and it stays free.
            </>}
            visual={<PrivacyVisual />}
          />
        </div>
      </section>

      {/* ───────────── HOW IT WORKS ───────────── */}
      <section id="how" className="relative mt-28 sm:mt-36 py-20 sm:py-28 bg-paper-deep/50">
        <div className="absolute inset-x-0 top-0 rule-hair" />
        <div className="absolute inset-x-0 bottom-0 rule-hair" />
        <div className="mx-auto max-w-6xl px-5 sm:px-8">
          <Reveal>
            <div className="mb-14 sm:mb-20 max-w-3xl">
              <div className="font-mono text-[0.72rem] uppercase tracking-[0.22em] text-ink-muted mb-3">
                No. II · how it works
              </div>
              <h2 className="font-display text-display-lg text-ink balance">
                Three layers, quietly stacked.
              </h2>
              <p className="mt-5 text-[1.05rem] leading-[1.65] text-ink-soft max-w-[52ch] pretty">
                Each part does one job. The engine speaks. The brain decides what to speak. The surface lets you
                press a key. None of them call the internet.
              </p>
            </div>
          </Reveal>
          <Reveal>
            <ArchitectureDiagram />
          </Reveal>
        </div>
      </section>

      {/* ───────────── WHY LOCAL ───────────── */}
      <section className="relative py-24 sm:py-32">
        <div className="mx-auto max-w-6xl px-5 sm:px-8">
          <Reveal>
            <div className="mb-14 sm:mb-20 max-w-3xl">
              <div className="font-mono text-[0.72rem] uppercase tracking-[0.22em] text-ink-muted mb-3">
                No. III · why local
              </div>
              <h2 className="font-display text-display-lg text-ink balance">
                Cloud TTS is convenient<br/>
                <span className="italic text-teal-deep">until it isn't.</span>
              </h2>
            </div>
          </Reveal>

          <div className="grid grid-cols-1 md:grid-cols-3 gap-7 md:gap-10">
            {[
              {
                h: "Privacy",
                b: "Whatever you select, whatever you summarise, whatever your Claude sessions produce — none of it touches a server. The text starts on your Mac and ends on your Mac.",
                stat: "0 bytes leave the device",
              },
              {
                h: "Cost",
                b: "Cloud voices charge per character, per minute, per month. Myna charges nothing, and will charge nothing, because there's no one to charge you.",
                stat: "$0 forever",
              },
              {
                h: "Latency",
                b: "A round trip to a TTS API is a beat you can feel. Local inference on Apple Silicon doesn't have that beat. You press the key, the voice starts.",
                stat: "≈ no perceptible delay",
              },
            ].map((c, i) => (
              <Reveal key={c.h} delay={i * 80}>
                <article className="relative rounded-2xl bg-paper-warm ring-1 ring-ink/8 p-7 h-full shadow-soft lift">
                  <div className="font-mono text-[0.7rem] uppercase tracking-[0.22em] text-rust mb-4">
                    {String(i + 1).padStart(2, "0")}
                  </div>
                  <h3 className="font-display text-[1.85rem] text-ink mb-3 tracking-tight">{c.h}.</h3>
                  <p className="text-[1.02rem] leading-[1.65] text-ink-soft pretty mb-6">{c.b}</p>
                  <div className="pt-4 border-t border-ink/8 font-mono text-[0.78rem] text-teal-deep numerals-tab">
                    {c.stat}
                  </div>
                </article>
              </Reveal>
            ))}
          </div>
        </div>
      </section>

      {/* ───────────── INSTALL ───────────── */}
      <section id="install" className="relative py-24 sm:py-32 bg-ink text-paper">
        <div className="mx-auto max-w-5xl px-5 sm:px-8">
          <Reveal>
            <div className="mb-12 sm:mb-16 max-w-3xl">
              <div className="font-mono text-[0.72rem] uppercase tracking-[0.22em] text-paper/45 mb-3">
                No. IV · install
              </div>
              <h2 className="font-display text-display-lg balance">
                Drag once.<br/>
                <span className="italic text-teal-glow">A small black bird in your menu bar.</span>
              </h2>
              <p className="mt-5 text-[1.05rem] leading-[1.65] text-paper/70 max-w-[52ch] pretty">
                Myna ships as a native, code-signed, notarised macOS app. Install with Homebrew or grab the DMG
                from GitHub Releases — either way, the local voice daemon comes along for the ride. macOS
                Ventura or later, Apple Silicon only.
              </p>
            </div>
          </Reveal>

          <Reveal delay={80}>
            <div className="grid gap-6 md:grid-cols-2 md:gap-8">
              <div>
                <CopyBlock
                  label="01 · homebrew"
                  lines={[
                    { comment: true, text: "Installs the app + the local daemon." },
                    { prompt: true, text: "brew install --cask PrerakGada/myna/myna" },
                    { comment: true, text: "" },
                    { comment: true, text: "Then launch it once and grant Accessibility" },
                    { comment: true, text: "when macOS asks. That's the whole setup." },
                  ]}
                />
              </div>
              <div>
                <CopyBlock
                  label="02 · or, download the dmg"
                  lines={[
                    { comment: true, text: "Latest signed + notarised .dmg" },
                    { prompt: true, text: "open https://github.com/PrerakGada/myna/releases/latest" },
                    { comment: true, text: "" },
                    { comment: true, text: "Drag Myna.app to Applications. Done." },
                  ]}
                />
              </div>
              <div className="md:col-span-2">
                <CopyBlock
                  label="03 · for summaries (optional)"
                  lines={[
                    { comment: true, text: "Summary hotkey uses a local LLM via Ollama." },
                    { comment: true, text: "Skip this if you only want straight selection-reading." },
                    { prompt: true, text: "brew install ollama" },
                    { prompt: true, text: "ollama pull qwen3.5:4b" },
                  ]}
                />
              </div>
            </div>
          </Reveal>

          <Reveal delay={140}>
            <div className="mt-12 sm:mt-16 grid gap-6 sm:grid-cols-3">
              <Detail label="Updates" value="Sparkle 2 · signed" />
              <Detail label="Min macOS" value="Ventura · 13.0" />
              <Detail label="License" value="MIT · open source" />
            </div>
          </Reveal>
        </div>
      </section>

      {/* ───────────── DEFAULT SHORTCUTS TABLE ───────────── */}
      <section className="relative py-24 sm:py-32">
        <div className="mx-auto max-w-4xl px-5 sm:px-8">
          <Reveal>
            <div className="mb-10 sm:mb-14">
              <div className="font-mono text-[0.72rem] uppercase tracking-[0.22em] text-ink-muted mb-3">
                Default shortcuts · all rebindable
              </div>
              <h2 className="font-display text-[2rem] sm:text-display-md text-ink balance">
                Five keys. <span className="italic text-teal-deep">No clashes.</span>
              </h2>
              <p className="mt-3 text-[1rem] leading-[1.65] text-ink-soft pretty max-w-[52ch]">
                Defaults use <Kbd keys={["cmd","alt","shift"]}/> so they don't collide with the
                shortcuts you already love. Rebind from the menu bar at any time.
              </p>
            </div>
          </Reveal>

          <Reveal delay={80}>
            <div className="rounded-2xl bg-paper-warm ring-1 ring-ink/8 shadow-soft overflow-hidden">
              <ul className="divide-y divide-ink/8">
                {[
                  { name: "Speak selection (full)",    keys: ["cmd","alt","shift","S"] },
                  { name: "Speak selection (summary)", keys: ["cmd","alt","shift","A"] },
                  { name: "Read Chrome article",       keys: ["cmd","alt","shift","R"] },
                  { name: "Pause / Resume",            keys: ["cmd","alt","shift","space"] },
                  { name: "Stop",                      keys: ["cmd","alt","shift","."] },
                ].map((r, i) => (
                  <li key={i} className="flex items-center justify-between gap-4 px-5 sm:px-7 py-4 sm:py-5 hover:bg-paper-deep/40 transition-colors">
                    <span className="text-[1.02rem] text-ink">{r.name}</span>
                    <Kbd keys={r.keys} />
                  </li>
                ))}
              </ul>
            </div>
          </Reveal>
        </div>
      </section>

      {/* ───────────── FAQ ───────────── */}
      <section id="faq" className="relative py-24 sm:py-32 bg-paper-deep/40">
        <div className="absolute inset-x-0 top-0 rule-hair" />
        <div className="mx-auto max-w-4xl px-5 sm:px-8">
          <Reveal>
            <div className="mb-10 sm:mb-14">
              <div className="font-mono text-[0.72rem] uppercase tracking-[0.22em] text-ink-muted mb-3">
                No. V · questions
              </div>
              <h2 className="font-display text-display-lg text-ink balance">
                Answered plainly.
              </h2>
            </div>
          </Reveal>
          <Reveal delay={80}>
            <FAQ />
          </Reveal>
        </div>
      </section>

      {/* ───────────── CLOSING / FOOTER ───────────── */}
      <section className="relative py-24 sm:py-32">
        <div className="mx-auto max-w-4xl px-5 sm:px-8 text-center">
          <Reveal>
            <div className="flex justify-center mb-6">
              <MynaMark size={56} />
            </div>
            <h2 className="font-display italic text-display-md text-ink balance">
              Made for people who'd<br className="hidden sm:inline"/> rather listen.
            </h2>
            <div className="mt-9 flex flex-col sm:flex-row items-center justify-center gap-3">
              <a href="#install" className="btn-primary">Install Myna</a>
              <a href={GITHUB_URL} target="_blank" rel="noopener noreferrer" className="btn-ghost">Star on GitHub</a>
            </div>
          </Reveal>
        </div>
      </section>

      <footer className="border-t border-ink/10 py-10 sm:py-14 bg-paper-warm/50">
        <div className="mx-auto max-w-6xl px-5 sm:px-8 flex flex-col sm:flex-row items-center justify-between gap-5">
          <div className="flex items-center gap-2.5">
            <MynaMark size={22} />
            <span className="font-display text-[1.05rem]">Myna</span>
            <span className="font-mono text-[0.72rem] text-ink-muted ml-2">native · MIT</span>
          </div>
          <div className="flex items-center gap-5 font-mono text-[0.78rem] text-ink-muted">
            <a href={GITHUB_URL} target="_blank" rel="noopener noreferrer" className="hover:text-ink transition-colors">github</a>
            <a href={`${GITHUB_URL}/issues`} target="_blank" rel="noopener noreferrer" className="hover:text-ink transition-colors">issues</a>
            <a href={`${GITHUB_URL}/blob/main/README.md`} target="_blank" rel="noopener noreferrer" className="hover:text-ink transition-colors">readme</a>
          </div>
          <div className="font-display italic text-[0.95rem] text-ink-muted">
            a quiet voice for your Mac.
          </div>
        </div>
      </footer>

      {/* mobile-only sticky install pill (shows after hero) */}
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
  accent,
}: {
  number: string;
  eyebrow: string;
  title: React.ReactNode;
  body: React.ReactNode;
  visual: React.ReactNode;
  reverse?: boolean;
  accent?: boolean;
}) {
  return (
    <Reveal>
      <div className="relative grid grid-cols-1 md:grid-cols-[minmax(0,1fr)_minmax(0,1fr)] gap-10 md:gap-16 items-center py-14 md:py-20">
        <div className={`min-w-0 ${reverse ? "md:order-2" : ""} max-w-[44ch]`}>
          <div className="flex items-center gap-3 mb-5">
            <span className="font-mono text-[0.72rem] tracking-[0.22em] uppercase text-rust numerals-tab">{number}</span>
            <span className="h-px w-8 bg-ink/20"/>
            <span className="font-mono text-[0.72rem] tracking-[0.22em] uppercase text-ink-muted">{eyebrow}</span>
          </div>
          <h3 className="font-display text-[2rem] sm:text-[2.4rem] md:text-[2.8rem] leading-[1.04] text-ink tracking-tight pretty">
            {title}
          </h3>
          <p className="mt-5 text-[1.05rem] sm:text-[1.1rem] leading-[1.65] text-ink-soft pretty">
            {body}
          </p>
        </div>
        <div className={`min-w-0 ${reverse ? "md:order-1" : ""}`}>
          <div className="relative">
            {accent && (
              <div aria-hidden="true" className="absolute -inset-6 -z-10 rounded-[28px] bg-gradient-to-br from-teal/8 via-transparent to-rust/8 blur-2xl" />
            )}
            {visual}
          </div>
        </div>
      </div>
    </Reveal>
  );
}

function Detail({ label, value }: { label: string; value: string }) {
  return (
    <div className="rounded-xl bg-paper/[0.04] ring-1 ring-paper/10 p-5">
      <div className="font-mono text-[0.7rem] uppercase tracking-[0.22em] text-paper/45 mb-1.5">{label}</div>
      <div className="font-display text-[1.15rem] text-paper">{value}</div>
    </div>
  );
}

/* ── mobile sticky CTA ───────────────────────────────────────────── */

import { MobileStickyCTA } from "@/components/MobileStickyCTA";
