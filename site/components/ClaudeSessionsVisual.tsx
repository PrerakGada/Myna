import { Soundwave } from "./Soundwave";

/**
 * The "five sessions finish, one voice at a time" visual.
 * Three queued, one playing, one done. Sitting calmly side-by-side.
 */
export function ClaudeSessionsVisual({ className }: { className?: string }) {
  const items = [
    { state: "playing",  tag: "refactor", title: "Extracted the audio router. 4 tests passing.", time: "now" },
    { state: "waiting",  tag: "docs",     title: "Drafted the install section. Ready when you are.", time: "12s" },
    { state: "waiting",  tag: "hotfix",   title: "Fixed the menu-bar pause regression.",            time: "1m" },
    { state: "waiting",  tag: "review",   title: "Walked through the daemon. Two suggestions inside.", time: "3m" },
    { state: "heard",    tag: "tests",    title: "Added the article-extraction integration test.",  time: "8m" },
  ] as const;

  return (
    <div className={`relative ${className ?? ""}`}>
      <div className="rounded-2xl bg-ink/[0.97] p-4 sm:p-5 text-paper shadow-[0_30px_60px_-20px_rgba(26,23,20,0.45)]">
        <div className="flex items-center justify-between mb-3">
          <span className="font-mono text-[0.7rem] uppercase tracking-[0.2em] text-paper/40">
            Claude Code · queue
          </span>
          <span className="font-mono text-[0.7rem] text-paper/40">5 sessions</span>
        </div>
        <ul className="space-y-1">
          {items.map((s, i) => (
            <li
              key={i}
              className={`flex items-center gap-2.5 sm:gap-3 rounded-lg px-2.5 py-2 transition-colors min-w-0 ${
                s.state === "playing" ? "bg-teal/15 ring-1 ring-teal/30" : "hover:bg-paper/5"
              }`}
            >
              {/* state dot */}
              <span className="shrink-0 inline-flex h-5 w-5 items-center justify-center">
                {s.state === "playing" ? (
                  <Soundwave bars={3} barWidth={2} gap={2} height={12} min={3} pace={1.4} className="text-teal-glow"/>
                ) : s.state === "heard" ? (
                  <svg viewBox="0 0 12 12" width="12" height="12" fill="none" stroke="currentColor" strokeWidth="1.6" className="text-paper/35"><path d="M2 6.5 5 9.5 10 3.5"/></svg>
                ) : (
                  <span className="block h-1.5 w-1.5 rounded-full bg-paper/30" />
                )}
              </span>
              <span className={`font-mono text-[0.7rem] uppercase tracking-wider w-14 shrink-0 ${
                s.state === "playing" ? "text-teal-glow" : s.state === "heard" ? "text-paper/30" : "text-rust"
              }`}>{s.tag}</span>
              <span className={`text-[0.85rem] truncate min-w-0 flex-1 ${
                s.state === "playing" ? "text-paper" : s.state === "heard" ? "text-paper/35 line-through decoration-paper/20" : "text-paper/80"
              }`}>{s.title}</span>
              <span className="font-mono text-[0.65rem] text-paper/35 shrink-0">{s.time}</span>
            </li>
          ))}
        </ul>
        <div className="mt-3 pt-3 border-t border-paper/10 flex items-center justify-between font-mono text-[0.7rem] text-paper/40">
          <span>↑↓ to move · ⏎ to hear</span>
          <span>1.0× · af_heart</span>
        </div>
      </div>
      {/* annotation */}
      <div className="absolute -bottom-4 left-4 right-4 sm:left-auto sm:-right-2 sm:bottom-auto sm:-top-3 sm:max-w-[200px] hidden sm:block">
        <div className="font-display italic text-[0.95rem] text-ink/60 leading-tight">
          you pick which one to hear.
        </div>
      </div>
    </div>
  );
}
