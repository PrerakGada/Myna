/**
 * Gestures and automation in one card: a trackpad with four fingers resting
 * on it (Myna's press-and-hold read gesture), and the myna:// links that let
 * Shortcuts, Raycast or BetterTouchTool drive it.
 */
export function HandsFreeVisual({ className }: { className?: string }) {
  const fingers = [
    { left: "25%", top: "40%" },
    { left: "40%", top: "30%" },
    { left: "55%", top: "28%" },
    { left: "70%", top: "36%" },
  ];
  return (
    <div className={`relative ${className ?? ""}`}>
      <div className="rounded-2xl bg-paper-warm p-5 shadow-soft ring-1 ring-ink/8 sm:p-6">
        <div className="flex items-center justify-between">
          <span className="font-mono text-[0.7rem] uppercase tracking-[0.18em] text-ink-muted">Trackpad</span>
          <span className="font-mono text-[0.7rem] text-teal">hold · reads the selection</span>
        </div>
        <div className="relative mx-auto mt-4 aspect-[16/10] w-full max-w-[380px] rounded-[18px] bg-gradient-to-b from-[#E9E1D0] to-[#DDD3BF] shadow-[inset_0_1px_0_rgba(255,255,255,0.7),inset_0_-2px_6px_rgba(26,23,20,0.08)] ring-1 ring-ink/10">
          {fingers.map((f, i) => (
            <span
              key={i}
              className="absolute h-[18%] w-[11%] -translate-x-1/2 -translate-y-1/2 rounded-full bg-ink/15 ring-2 ring-teal/50"
              style={{ left: f.left, top: f.top, animation: `pulseSlow 2.4s ease-in-out ${i * 0.08}s infinite` }}
            />
          ))}
          <span className="absolute bottom-3 left-1/2 -translate-x-1/2 whitespace-nowrap font-mono text-[0.65rem] text-ink-muted">
            four fingers, about a third of a second
          </span>
        </div>
      </div>

      <div className="code-block relative -mt-4 ml-6 mr-2 text-[0.8rem] shadow-[0_18px_40px_-16px_rgba(26,23,20,0.5)] sm:ml-12 sm:mr-[-12px]">
        <div><span className="comment"># from Shortcuts, Raycast, Alfred or BetterTouchTool</span></div>
        <div><span className="prompt">open </span>myna://speak-selection</div>
        <div><span className="prompt">open </span>myna://toggle-pause</div>
        <div><span className="prompt">open </span>&quot;myna://speed?value=1.5&quot;</div>
      </div>
    </div>
  );
}
