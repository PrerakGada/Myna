import { Kbd } from "./Kbd";

const ROWS = [
  { name: "Speak selection (full)",    keys: ["cmd", "alt", "shift", "S"] },
  { name: "Speak selection (summary)", keys: ["cmd", "alt", "shift", "A"] },
  { name: "Read article",              keys: ["cmd", "alt", "shift", "R"] },
  { name: "Pause / resume",            keys: ["cmd", "alt", "shift", "space"] },
  { name: "Stop",                      keys: ["cmd", "alt", "shift", "."] },
];

export function ControlVisual({ className }: { className?: string }) {
  return (
    <div className={`rounded-2xl bg-paper-warm shadow-soft ring-1 ring-ink/8 overflow-hidden ${className ?? ""}`}>
      <div className="flex items-center justify-between px-4 py-3 border-b border-ink/8 bg-paper-deep/40">
        <span className="font-mono text-[0.7rem] uppercase tracking-[0.18em] text-ink-muted">
          Customise Shortcuts
        </span>
        <span className="font-mono text-[0.65rem] text-ink-muted">all rebindable</span>
      </div>
      <ul className="divide-y divide-ink/8">
        {ROWS.map((r, i) => (
          <li key={i} className="flex items-center justify-between gap-3 px-4 py-3">
            <span className="text-[0.92rem] text-ink-soft">{r.name}</span>
            <Kbd keys={r.keys} />
          </li>
        ))}
      </ul>
      <div className="px-4 py-2.5 border-t border-ink/8 bg-paper-deep/40 flex items-center justify-between">
        <span className="font-mono text-[0.65rem] text-ink-muted">Press a chord to rebind</span>
        <span className="font-mono text-[0.65rem] text-teal">○ recording…</span>
      </div>
    </div>
  );
}
