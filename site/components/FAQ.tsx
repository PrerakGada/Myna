"use client";

import { useState } from "react";

type Item = { q: string; a: React.ReactNode };

function Code({ children }: { children: React.ReactNode }) {
  return <code className="font-mono text-[0.88em] text-ink bg-ink/[0.05] rounded px-1 py-0.5">{children}</code>;
}

const ITEMS: Item[] = [
  {
    q: "What do I need to run Myna?",
    a: <>A Mac with Apple Silicon (M1 or later) running macOS 14 Sonoma or newer, and about 1&nbsp;GB of free space for the voice. The speech engine is built on Apple&rsquo;s MLX framework, which only runs on Apple Silicon, so Intel Macs can&rsquo;t run it.</>,
  },
  {
    q: "What happens the first time I open it?",
    a: <>A setup window installs Myna&rsquo;s voice into your user account: a private copy of Python, the MLX speech engine (about 600&nbsp;MB), a small background service, and the Kokoro voice model (about 370&nbsp;MB). Each step shows its progress. No Terminal, no admin password, and a few minutes on a good connection. If you use Claude Code, it connects that too. Then it asks for Accessibility, which it needs to copy the text you select.</>,
  },
  {
    q: "Is it really free?",
    a: <>Yes. No price, no account, no usage limits, and nothing to upgrade to. The source is MIT-licensed on GitHub.</>,
  },
  {
    q: "Does what I read leave my Mac?",
    a: <>The voice is generated on your Mac by the Kokoro model, so the text you read is never sent to a speech service, and summaries run through Ollama on your own machine. Myna does touch the network in three specific cases: downloading its voice during setup, checking GitHub for app updates, and, when you use <em>Read article</em>, fetching that page from the web the way your browser did. The app has no analytics and no telemetry. This website counts page views and downloads with its own cookieless counter: no cookies, no IP addresses stored, nothing shared.</>,
  },
  {
    q: "Which voices can I use?",
    a: <>Four natural US-English Kokoro voices: Heart (the default), Bella, Michael and Adam. Switch from the menu bar, or preview them in Settings → Voice. Speed runs from 0.5× to 2× without changing the pitch.</>,
  },
  {
    q: "Which apps and browsers does it work with?",
    a: <>Reading a selection with <Code>⌘⌥⇧S</Code> works in any app you can copy text from: browsers, PDFs, editors, mail, Slack, terminals. <em>Read article</em> (<Code>⌘⌥⇧R</Code>) reads the front tab of Google Chrome. In full-screen terminal apps like Claude Code, hold <Code>⌥</Code> while you drag so the terminal makes a real selection.</>,
  },
  {
    q: "How does the Claude Code part work?",
    a: <>Setup adds a small Stop hook to Claude Code. When a session finishes, its reply appears in Myna&rsquo;s floating player as <em>New output ready</em>, with Play and Dismiss. Play reads the whole reply in your voice. If several sessions finish together, their replies come one at a time, so nothing talks over anything else, and the menu bar lists the ones waiting, tagged by project.</>,
  },
  {
    q: "Can it summarize instead of reading everything?",
    a: <>Yes: <Code>⌘⌥⇧A</Code> summarizes the selection and reads the summary. It needs Ollama running on your Mac with the <Code>qwen3.5:4b</Code> model (<Code>brew install ollama</Code>, then <Code>ollama pull qwen3.5:4b</Code>). Plain reading doesn&rsquo;t need any of that.</>,
  },
  {
    q: "Can I drive it from Shortcuts, Raycast or BetterTouchTool?",
    a: <>Yes. Anything that can open a URL can drive Myna: <Code>myna://speak-selection</Code>, <Code>myna://read-chrome</Code>, <Code>myna://toggle-pause</Code>, <Code>myna://stop</Code>, <Code>myna://seek?delta=-15</Code> and <Code>myna://speed?value=1.5</Code>.</>,
  },
  {
    q: "How is it different from macOS’s built-in Speak Selection?",
    a: <>Kokoro is a modern neural voice that stays pleasant through a long essay. Around it Myna adds a floating player you can scrub and speed up, clean article extraction, Claude Code replies, a list of recent reads you can replay, trackpad gestures, and URL automation.</>,
  },
  {
    q: "How does it update?",
    a: <>Through Sparkle: signed updates published on GitHub Releases, offered right inside the app. A disk-image install also keeps its background service in step with the app after each update.</>,
  },
  {
    q: "How do I uninstall it?",
    a: <>
      Quit Myna and drag it to the Trash. To remove its voice as well:
      <pre className="code-block mt-3 text-[0.8rem] whitespace-pre-wrap break-all">{`launchctl bootout gui/$(id -u)/dev.myna.daemon
rm -rf ~/Library/LaunchAgents/dev.myna.daemon.plist \\
  ~/.venvs/myna-daemon ~/.venvs/mlx-audio \\
  ~/Library/Application\\ Support/Myna ~/.config/myna \\
  ~/.cache/huggingface/hub/models--prince-canuma--Kokoro-82M`}</pre>
      <span className="block mt-3">If you connected Claude Code, also delete the <Code>myna-cc-announce.py</Code> entry from <Code>~/.claude/settings.json</Code>. Installed with Homebrew? <Code>brew uninstall --cask myna</Code> and <Code>brew uninstall myna-daemon</Code>.</span>
    </>,
  },
];

export function FAQ() {
  const [open, setOpen] = useState<number | null>(0);

  return (
    <ul className="divide-y divide-ink/10 border-y border-ink/10">
      {ITEMS.map((item, i) => {
        const isOpen = open === i;
        return (
          <li key={item.q}>
            <button
              type="button"
              onClick={() => setOpen(isOpen ? null : i)}
              aria-expanded={isOpen}
              className="w-full flex items-start justify-between gap-6 py-5 sm:py-6 text-left group"
            >
              <span className="font-display text-[1.15rem] sm:text-[1.35rem] text-ink leading-snug pretty">
                {item.q}
              </span>
              <span
                aria-hidden="true"
                className={`mt-2 shrink-0 inline-flex h-6 w-6 items-center justify-center text-ink/50 transition-transform duration-300 ${
                  isOpen ? "rotate-45 text-teal" : ""
                }`}
              >
                <svg viewBox="0 0 12 12" width="14" height="14" fill="none" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round">
                  <line x1="6" y1="2" x2="6" y2="10" />
                  <line x1="2" y1="6" x2="10" y2="6" />
                </svg>
              </span>
            </button>
            <div
              className="grid transition-[grid-template-rows] duration-500"
              style={{ gridTemplateRows: isOpen ? "1fr" : "0fr" }}
            >
              <div className="overflow-hidden">
                <div className="pb-6 sm:pb-7 pr-2 sm:pr-10 text-[1.02rem] sm:text-[1.08rem] leading-[1.65] text-ink-soft pretty">
                  {item.a}
                </div>
              </div>
            </div>
          </li>
        );
      })}
    </ul>
  );
}
