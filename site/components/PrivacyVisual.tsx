/**
 * A single visual that says "everything stays on the Mac".
 * A laptop silhouette holding the entire pipeline; a dashed line to "cloud"
 * that ends in a polite X.
 */
export function PrivacyVisual({ className }: { className?: string }) {
  return (
    <div className={`relative ${className ?? ""}`}>
      <div className="rounded-2xl bg-paper-warm shadow-soft ring-1 ring-ink/8 p-5 sm:p-7 relative overflow-hidden">
        {/* the mac silhouette */}
        <div className="relative mx-auto max-w-[380px]">
          <div className="rounded-t-xl bg-ink/95 px-3 pt-3 pb-2 ring-1 ring-ink">
            <div className="rounded-md bg-paper/[0.04] p-3 min-h-[140px] relative">
              {/* contents: the three local pieces */}
              <div className="flex items-center gap-1.5 mb-2">
                <span className="h-1.5 w-1.5 rounded-full bg-rust/70"/>
                <span className="h-1.5 w-1.5 rounded-full bg-ink/30"/>
                <span className="h-1.5 w-1.5 rounded-full bg-ink/30"/>
              </div>
              <div className="grid grid-cols-3 gap-2 mt-3">
                {["Kokoro voice", "Qwen summary", "Daemon + UI"].map((n) => (
                  <div key={n} className="rounded-md bg-teal/15 ring-1 ring-teal/30 p-2">
                    <div className="font-mono text-[0.55rem] uppercase tracking-wider text-teal-glow/80">local</div>
                    <div className="font-display text-[0.78rem] text-paper mt-0.5 leading-tight">{n}</div>
                  </div>
                ))}
              </div>
              <div className="mt-3 text-[0.7rem] font-mono text-paper/45 text-center">
                ↑ everything runs here
              </div>
            </div>
          </div>
          {/* hinge */}
          <div className="h-1.5 bg-ink/85 rounded-b-xl"/>
          <div className="mx-auto h-3 w-[55%] bg-gradient-to-b from-ink-soft/30 to-transparent rounded-b-[10px]"/>
        </div>

        {/* dashed connection to cloud — terminated */}
        <div aria-hidden="true" className="absolute top-8 right-3 sm:right-6 flex items-center gap-2">
          <svg width="56" height="40" viewBox="0 0 56 40" className="text-ink/25">
            <path d="M 2 36 Q 25 8, 50 6" stroke="currentColor" strokeWidth="1" strokeDasharray="3 4" fill="none" strokeLinecap="round"/>
          </svg>
          <div className="relative">
            <div className="rounded-lg bg-paper px-2.5 py-1.5 ring-1 ring-ink/15 font-mono text-[0.65rem] text-ink-muted">
              cloud TTS
            </div>
            <span className="absolute -top-1.5 -right-1.5 inline-flex h-5 w-5 items-center justify-center rounded-full bg-rust text-paper text-[0.8rem] leading-none font-bold">×</span>
          </div>
        </div>
      </div>
    </div>
  );
}
