"use client";

import { Soundwave } from "./Soundwave";
import { MynaMark } from "./MynaMark";

/**
 * The hero visual: a stylized macOS menu-bar with the Myna icon
 * showing an open dropdown mid-playback. This is the "show the
 * product in motion" piece — but it's a single, controlled motion
 * so it doesn't feel like a carnival.
 */
export function MenubarMockup({ className }: { className?: string }) {
  return (
    <div className={`relative mx-auto w-full max-w-[560px] ${className ?? ""}`}>
      {/* desk surface / shadow */}
      <div className="absolute -inset-x-4 -inset-y-3 -z-10 rounded-[28px] bg-gradient-to-br from-paper-warm to-paper-deep shadow-page" />

      {/* the menu-bar strip */}
      <div className="menubar-mockup px-3 py-1.5 flex items-center justify-between text-paper text-[11px] font-mono">
        <div className="flex items-center gap-3">
          <span className="opacity-80">Finder</span>
          <span className="opacity-50">File</span>
          <span className="opacity-50 hidden sm:inline">Edit</span>
          <span className="opacity-50 hidden sm:inline">View</span>
        </div>
        <div className="flex items-center gap-3">
          <span className="opacity-60 hidden sm:inline-flex items-center gap-1">
            <span className="inline-block h-1.5 w-1.5 rounded-full bg-teal-glow animate-pulse-slow"/>
            kokoro
          </span>
          <div className="inline-flex items-center gap-1 rounded bg-white/10 px-1.5 py-1">
            <MynaMark size={14} className="-mt-px"/>
            <Soundwave bars={5} barWidth={2} gap={2} height={10} min={3} pace={1.2}/>
          </div>
          <span className="opacity-70 numerals-tab hidden sm:inline">100%</span>
          <span className="opacity-70 numerals-tab">Sat 5:24</span>
        </div>
      </div>

      {/* the dropdown panel */}
      <div className="relative -mt-px overflow-hidden rounded-b-[18px] bg-ink/[0.97] text-paper backdrop-blur-xl shadow-[0_30px_60px_-20px_rgba(26,23,20,0.5)]">
        {/* now-playing strip */}
        <div className="px-4 py-3.5 border-b border-paper/10">
          <div className="flex items-center justify-between gap-3 min-w-0">
            <div className="flex items-center gap-2.5 min-w-0 flex-1">
              <div className="h-7 w-7 shrink-0 rounded-full bg-teal/25 ring-1 ring-teal/40 flex items-center justify-center">
                <Soundwave bars={3} barWidth={2} gap={2} height={12} min={3} pace={1.4} className="text-teal-glow"/>
              </div>
              <div className="min-w-0 flex-1">
                <div className="text-[11px] uppercase tracking-widest text-paper/45 font-mono">Now reading</div>
                <div className="text-[13px] text-paper/95 truncate">selection from <span className="italic">The Quiet Web</span></div>
              </div>
            </div>
            <div className="flex items-center gap-1.5 shrink-0">
              <button aria-label="Pause" className="h-7 w-7 rounded-full bg-paper/10 hover:bg-paper/20 transition-colors flex items-center justify-center">
                <svg viewBox="0 0 12 12" width="10" height="10" fill="currentColor"><rect x="3" y="2.5" width="2" height="7" rx="1"/><rect x="7" y="2.5" width="2" height="7" rx="1"/></svg>
              </button>
              <button aria-label="Stop" className="h-7 w-7 rounded-full bg-paper/10 hover:bg-paper/20 transition-colors flex items-center justify-center">
                <svg viewBox="0 0 12 12" width="10" height="10" fill="currentColor"><rect x="3" y="3" width="6" height="6" rx="1.2"/></svg>
              </button>
            </div>
          </div>

          {/* progress / wave */}
          <div className="mt-2.5 flex items-center gap-2 min-w-0">
            <span className="text-[10px] font-mono text-paper/45 numerals-tab w-8 shrink-0">0:42</span>
            <div className="flex-1 min-w-0 overflow-hidden">
              <Soundwave bars={26} barWidth={2} gap={2} height={18} min={3} pace={1} className="text-paper/70"/>
            </div>
            <span className="text-[10px] font-mono text-paper/45 numerals-tab w-8 text-right shrink-0">2:18</span>
          </div>
        </div>

        {/* claude code queue */}
        <div className="px-4 py-3">
          <div className="text-[10px] uppercase tracking-[0.15em] text-paper/40 font-mono mb-2">
            Claude Code · 3 sessions waiting
          </div>
          <ul className="space-y-1.5">
            {[
              { tag: "refactor", line: "Extracted the audio router. 4 tests added.", time: "just now" },
              { tag: "docs",     line: "Drafted the install section.",                time: "12s" },
              { tag: "hotfix",   line: "Fixed the menu-bar pause regression.",         time: "1m" },
            ].map((s, i) => (
              <li key={i} className="flex items-center gap-2.5 rounded-lg px-2 py-1.5 hover:bg-paper/5 transition-colors group cursor-pointer min-w-0">
                <span className="inline-flex h-1.5 w-1.5 rounded-full bg-teal-glow shrink-0" />
                <span className="text-[10px] font-mono text-rust uppercase tracking-wider w-12 shrink-0">{s.tag}</span>
                <span className="text-[12.5px] text-paper/90 truncate min-w-0 flex-1">{s.line}</span>
                <span className="text-[10px] font-mono text-paper/40 shrink-0">{s.time}</span>
              </li>
            ))}
          </ul>
        </div>

        {/* footer row */}
        <div className="border-t border-paper/10 px-4 py-2.5 flex items-center justify-between text-[10.5px] font-mono text-paper/45">
          <span>Speed <span className="text-paper/80">1.0×</span></span>
          <span className="hidden sm:inline">Voice <span className="text-paper/80">af_heart</span></span>
          <span>Customize shortcuts…</span>
        </div>
      </div>

      {/* hand-drawn callout arrow + label, hidden on mobile to save space */}
      <div className="absolute -top-3 -right-3 hidden md:flex items-center gap-2 -rotate-3">
        <span className="font-display italic text-ink/60 text-[0.9rem]">the menu bar</span>
        <svg width="44" height="22" viewBox="0 0 44 22" fill="none" className="text-ink/40">
          <path d="M2 18 C 12 10, 24 6, 40 4" stroke="currentColor" strokeWidth="1" strokeLinecap="round" strokeDasharray="2 3"/>
          <path d="M40 4 L 34 4 M40 4 L 38 9" stroke="currentColor" strokeWidth="1" strokeLinecap="round" fill="none"/>
        </svg>
      </div>
    </div>
  );
}
