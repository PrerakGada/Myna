import { Kbd } from "./Kbd";

/**
 * A two-pane visual: a noisy cluttered article on the left
 * (ads, banners, sidebar) and the extracted clean reading version
 * on the right with a waveform pulsing through it.
 */
export function ArticleVisual({ className }: { className?: string }) {
  return (
    <div className={`relative ${className ?? ""}`}>
      <div className="grid grid-cols-2 gap-3 sm:gap-4">
        {/* messy original */}
        <div className="rounded-xl bg-paper-warm shadow-soft ring-1 ring-ink/8 overflow-hidden">
          <div className="flex gap-1 px-2.5 py-2 bg-paper-deep/60 border-b border-ink/8">
            <span className="h-2 w-2 rounded-full bg-ink/15"/>
            <span className="h-2 w-2 rounded-full bg-ink/15"/>
            <span className="h-2 w-2 rounded-full bg-ink/15"/>
          </div>
          <div className="p-3 space-y-2">
            {/* banner ad */}
            <div className="h-7 rounded bg-rust/15 ring-1 ring-rust/20 flex items-center justify-center">
              <span className="font-mono text-[0.55rem] uppercase tracking-wider text-rust/70">advertisement</span>
            </div>
            {/* fake title */}
            <div className="h-2.5 w-3/4 rounded-full bg-ink/15"/>
            {/* fake body lines, broken by clutter */}
            <div className="h-1.5 w-full rounded-full bg-ink/10"/>
            <div className="h-1.5 w-[92%] rounded-full bg-ink/10"/>
            <div className="h-6 rounded bg-teal/10 ring-1 ring-teal/20 flex items-center justify-center">
              <span className="font-mono text-[0.55rem] tracking-wider text-teal/70">newsletter signup</span>
            </div>
            <div className="h-1.5 w-[88%] rounded-full bg-ink/10"/>
            <div className="h-1.5 w-full rounded-full bg-ink/10"/>
            <div className="h-1.5 w-[70%] rounded-full bg-ink/10"/>
            <div className="h-5 rounded bg-rust/15 ring-1 ring-rust/20 flex items-center justify-center">
              <span className="font-mono text-[0.55rem] uppercase tracking-wider text-rust/70">ad</span>
            </div>
          </div>
        </div>

        {/* clean extracted */}
        <div className="rounded-xl bg-ink text-paper shadow-soft overflow-hidden">
          <div className="flex items-center gap-1.5 px-2.5 py-2 border-b border-paper/10">
            <span className="h-2 w-2 rounded-full bg-teal-glow"/>
            <span className="font-mono text-[0.6rem] uppercase tracking-wider text-paper/60">reading</span>
          </div>
          <div className="p-3 space-y-2">
            <div className="h-2.5 w-3/4 rounded-full bg-paper/30"/>
            <div className="h-1.5 w-full rounded-full bg-paper/15"/>
            <div className="h-1.5 w-[94%] rounded-full bg-paper/15"/>
            <div className="h-1.5 w-[88%] rounded-full bg-paper/15"/>
            <div className="h-1.5 w-full rounded-full bg-paper/15"/>
            <div className="h-1.5 w-[91%] rounded-full bg-paper/15"/>
            <div className="h-1.5 w-[78%] rounded-full bg-paper/15"/>
            <div className="h-1.5 w-full rounded-full bg-paper/15"/>
            <div className="h-1.5 w-[85%] rounded-full bg-paper/15"/>
            {/* waveform "playing" line */}
            <div className="flex items-center gap-1 pt-1">
              {[0.4, 0.7, 0.5, 0.9, 0.6, 0.8, 0.45, 0.7, 0.55, 0.95, 0.5, 0.7, 0.4].map((h, i) => (
                <span
                  key={i}
                  className="block w-[2px] rounded-full bg-teal-glow"
                  style={{ height: `${h * 18}px`, opacity: 0.7 + h * 0.3 }}
                />
              ))}
            </div>
          </div>
        </div>
      </div>

      {/* arrow between */}
      <div aria-hidden="true" className="absolute left-1/2 top-[42%] -translate-x-1/2 -translate-y-1/2 z-10">
        <div className="rounded-full bg-paper p-1.5 shadow-soft ring-1 ring-ink/10">
          <Kbd keys={["cmd", "alt", "shift", "R"]} className="text-[0.7rem]"/>
        </div>
      </div>
    </div>
  );
}
