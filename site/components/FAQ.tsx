"use client";

import { useState } from "react";

type Item = { q: string; a: React.ReactNode };

const ITEMS: Item[] = [
  {
    q: "Is Myna only for Apple Silicon Macs?",
    a: <>Yes. The voice model runs through mlx-audio, which is built specifically for Apple Silicon. Intel Macs aren't supported and probably won't be.</>,
  },
  {
    q: "Is it really free?",
    a: <>Yes, in both senses. Free as in no payment, ever. Free as in MIT-licensed source you can read, fork, and modify. There's no paid tier waiting in the wings.</>,
  },
  {
    q: "Does my text ever leave my Mac?",
    a: <>No. The voice model is local. The summariser is local. There's no analytics, no telemetry, no remote call. If your Mac is offline, Myna still works.</>,
  },
  {
    q: "Which voice does it use? Can I change it?",
    a: <>The default is Kokoro's <span className="font-mono text-ink-soft">af_heart</span>, a warm voice that holds up well at length. Other Kokoro voices can be swapped in by editing the daemon config; a friendlier voice picker is on the roadmap.</>,
  },
  {
    q: "Does it work with Safari or Firefox?",
    a: <>The "read this article" feature currently targets Chrome. Selection reading (<span className="font-mono text-ink-soft">⌘⌥⇧S</span>) works in any app, including Safari and Firefox, because it operates on selected text rather than the page itself.</>,
  },
  {
    q: "How is this different from the macOS built-in speech?",
    a: <>The system voices are fine for short alerts and accessibility prompts, less so for reading a long essay or a Claude Code response. Kokoro is a newer, more natural model, and Myna adds the things the built-in speech doesn't have: a global summary hotkey, article extraction, Claude Code session narration, and a proper menu-bar control surface.</>,
  },
  {
    q: "What is the Claude Code integration actually for?",
    a: <>If you run one Claude session at a time, it's a nice convenience: when the session finishes, the response can be read aloud. If you run several in parallel, it's the real reason Myna exists. Each finished session queues silently in the menu bar and waits for you to pick which one to hear. Nothing talks over anything else.</>,
  },
  {
    q: "How do I uninstall?",
    a: <>Unload the two LaunchAgents (<span className="font-mono text-ink-soft">launchctl unload …/dev.myna.engine.plist</span> and the daemon one), delete <span className="font-mono text-ink-soft">~/.hammerspoon/myna.lua</span>, remove the Claude Code Stop hook from <span className="font-mono text-ink-soft">~/.claude/settings.json</span>, and delete the repo folder. Myna doesn't scatter files across your system, so cleanup is quick.</>,
  },
];

export function FAQ() {
  const [open, setOpen] = useState<number | null>(0);

  return (
    <ul className="divide-y divide-ink/10 border-y border-ink/10">
      {ITEMS.map((item, i) => {
        const isOpen = open === i;
        return (
          <li key={i}>
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
                <div className="pb-6 sm:pb-7 pr-10 text-[1.02rem] sm:text-[1.08rem] leading-[1.65] text-ink-soft pretty">
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
