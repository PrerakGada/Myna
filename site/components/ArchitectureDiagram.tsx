/**
 * App → Daemon → Voice — a calm, editorial diagram. Mobile becomes
 * a vertical timeline; desktop a horizontal flow. No SVG curves that
 * compute differently on render; all CSS.
 */
export function ArchitectureDiagram() {
  const layers = [
    {
      tag: "01",
      name: "App",
      sub: "Native SwiftUI · AVAudioEngine",
      body: "The menu bar, the hotkeys, the Settings panel, the playback. AVAudioEngine handles speed without pitch shift and lets you scrub or jump ±15s. Signed, notarised, and quietly updated by Sparkle.",
    },
    {
      tag: "02",
      name: "Daemon",
      sub: "Python · FastAPI · streams WAV",
      body: "A small local service that synthesises in chunks and streams them to the app as the voice plays. Extracts articles, summarises through Ollama, never opens a socket beyond 127.0.0.1.",
    },
    {
      tag: "03",
      name: "Voice",
      sub: "mlx-audio · Kokoro af_heart",
      body: "The Kokoro model running natively on Apple Silicon. Fast because it's local. Warm because Kokoro is just a genuinely good model.",
    },
  ];

  return (
    <div className="relative">
      {/* connecting line, mobile (vertical) */}
      <div aria-hidden="true" className="absolute left-[15px] top-2 bottom-2 w-px bg-gradient-to-b from-transparent via-ink/20 to-transparent md:hidden" />
      {/* connecting line, desktop (horizontal) */}
      <div aria-hidden="true" className="absolute top-[22px] left-[8%] right-[8%] h-px bg-gradient-to-r from-transparent via-ink/20 to-transparent hidden md:block" />

      <ol className="grid grid-cols-1 gap-7 md:grid-cols-3 md:gap-10">
        {layers.map((l) => (
          <li key={l.tag} className="relative pl-10 md:pl-0">
            {/* node */}
            <div className="absolute left-0 top-0 md:relative md:left-auto md:top-auto md:mb-5 flex items-center md:justify-start">
              <span className="relative inline-flex h-[30px] w-[30px] items-center justify-center rounded-full bg-paper-warm shadow-chip">
                <span className="block h-2 w-2 rounded-full bg-teal"/>
                <span className="absolute inset-0 rounded-full ring-1 ring-ink/15"/>
              </span>
              <span className="ml-3 hidden md:inline font-mono text-[0.72rem] tracking-[0.18em] uppercase text-ink-muted">
                Layer {l.tag}
              </span>
            </div>
            <div>
              <div className="md:hidden font-mono text-[0.72rem] tracking-[0.18em] uppercase text-ink-muted mb-1">
                Layer {l.tag}
              </div>
              <h3 className="font-display text-[1.6rem] sm:text-[1.85rem] leading-[1.05] text-ink">
                {l.name}.
              </h3>
              <p className="mt-1 font-mono text-[0.78rem] text-rust">{l.sub}</p>
              <p className="mt-3 text-[1.02rem] leading-[1.65] text-ink-soft pretty max-w-sm">
                {l.body}
              </p>
            </div>
          </li>
        ))}
      </ol>
    </div>
  );
}
