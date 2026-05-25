import { Kbd } from "./Kbd";
import { Soundwave } from "./Soundwave";

/**
 * A mock browser window showing selected text and the keyboard chord
 * floating beside it. Communicates "select → press → listen" in one frame.
 */
export function SelectionVisual({ className }: { className?: string }) {
  return (
    <div className={`relative ${className ?? ""}`}>
      <div className="rounded-2xl bg-paper-warm shadow-soft ring-1 ring-ink/8 overflow-hidden">
        {/* chrome */}
        <div className="flex items-center gap-2 px-3 py-2.5 bg-paper-deep/60 border-b border-ink/8 min-w-0">
          <span className="h-2.5 w-2.5 rounded-full bg-rust/70 shrink-0" />
          <span className="h-2.5 w-2.5 rounded-full bg-ink/15 shrink-0" />
          <span className="h-2.5 w-2.5 rounded-full bg-ink/15 shrink-0" />
          <div className="ml-2 flex-1 min-w-0 rounded-md bg-paper-warm/80 ring-1 ring-ink/8 px-2.5 py-1 text-[0.72rem] font-mono text-ink-muted truncate">
            the-quiet-web.com/essays/on-listening
          </div>
        </div>
        {/* article body */}
        <div className="px-5 sm:px-7 py-6 sm:py-7">
          <p className="font-display text-[1.5rem] sm:text-[1.65rem] leading-[1.1] text-ink mb-3 tracking-tight">
            On Listening
          </p>
          <p className="text-[0.98rem] leading-[1.7] text-ink-soft pretty">
            There is a particular hour of the afternoon when the screen begins to{" "}
            <span className="relative bg-teal/20 text-ink rounded px-0.5 -mx-0.5">
              gauze over, when the prose you owe the day grows heavier than it should, and you find yourself reading the same paragraph for the third time.
              <span aria-hidden="true" className="absolute -bottom-[2px] left-0 right-0 h-[1.5px] bg-teal/60" />
            </span>{" "}
            That is the hour Myna was built for.
          </p>
        </div>
      </div>

      {/* floating chord card */}
      <div className="absolute -bottom-5 right-4 sm:-bottom-6 sm:-right-6 rounded-xl bg-ink text-paper px-3.5 py-2.5 shadow-[0_18px_40px_-12px_rgba(26,23,20,0.45)] flex items-center gap-3">
        <Kbd keys={["cmd", "alt", "shift", "S"]} />
        <span className="text-[0.78rem] font-display tracking-tight">speak it</span>
        <span className="h-3 w-px bg-paper/20" />
        <Soundwave bars={5} barWidth={2} gap={2} height={14} pace={1.3} className="text-teal-glow"/>
      </div>
    </div>
  );
}
