import { Kbd } from "./Kbd";
import { BirdGlyph, SYSTEM_FONT } from "./mac/Glyphs";
import { PillMock } from "./mac/PillMock";

/**
 * The hero: a Mac desktop mid-read. A paragraph is selected in a document,
 * the chord that read it floats beside it, and Myna's pill plays at the
 * bottom of the screen — the whole loop in one frame.
 */
export function HeroScene({ className }: { className?: string }) {
  return (
    <div className={`relative mx-auto w-full max-w-[600px] ${className ?? ""}`}>
      <div
        className="relative overflow-hidden rounded-[22px] shadow-page ring-1 ring-ink/10"
        style={{ background: "linear-gradient(155deg, #33625A 0%, #1F4540 48%, #151F1D 100%)" }}
      >
        {/* menu bar */}
        <div
          className="flex items-center justify-between bg-black/25 px-4 py-[5px] text-[11px] text-white/85"
          style={{ fontFamily: SYSTEM_FONT }}
        >
          <div className="flex items-center gap-3.5">
            <span className="font-semibold">Preview</span>
            <span className="text-white/70">File</span>
            <span className="text-white/70">Edit</span>
            <span className="hidden text-white/70 sm:inline">View</span>
          </div>
          <div className="flex items-center gap-3">
            <span className="inline-flex items-center rounded-[5px] bg-white/15 px-1.5 py-[1px]">
              <BirdGlyph size={13} />
            </span>
            <span className="tabular-nums text-white/80">Thu 5:24 PM</span>
          </div>
        </div>

        {/* document window */}
        <div className="px-4 pb-[150px] pt-5 sm:px-9 sm:pb-[132px] sm:pt-7">
          <div className="overflow-hidden rounded-[12px] bg-[#FBF8F1] shadow-[0_24px_50px_-20px_rgba(0,0,0,0.6)]">
            <div className="flex items-center gap-1.5 border-b border-ink/[0.07] bg-[#F1ECE1] px-3 py-2">
              <span className="h-2.5 w-2.5 rounded-full bg-[#FF5F57]" />
              <span className="h-2.5 w-2.5 rounded-full bg-[#FEBC2E]" />
              <span className="h-2.5 w-2.5 rounded-full bg-[#28C840]" />
              <span className="ml-3 truncate text-[11px] text-ink-muted" style={{ fontFamily: SYSTEM_FONT }}>
                on-listening.pdf
              </span>
            </div>
            <div className="px-5 py-5 sm:px-7 sm:py-6">
              <p className="font-display text-[1.35rem] leading-tight tracking-tight text-ink sm:text-[1.55rem]">On listening</p>
              <p className="mt-3 text-[0.95rem] leading-[1.7] text-ink-soft pretty">
                There is a particular hour of the afternoon when{" "}
                <span className="rounded-[3px] bg-[rgba(10,132,255,0.22)] text-ink">
                  the screen turns to gauze, when the prose you still owe the day grows heavier than it should, and you read the same paragraph three times.
                </span>{" "}
                That is the hour a voice does better than your eyes.
              </p>
              <div className="mt-4 space-y-2" aria-hidden="true">
                <div className="h-1.5 w-full rounded-full bg-ink/[0.07]" />
                <div className="h-1.5 w-[92%] rounded-full bg-ink/[0.07]" />
                <div className="h-1.5 w-[64%] rounded-full bg-ink/[0.07]" />
              </div>
            </div>
          </div>
        </div>

        {/* the pill, where Myna puts it: bottom centre of the screen */}
        <div className="absolute inset-x-0 bottom-4 flex justify-center px-3 sm:bottom-6">
          <PillMock headline="the screen turns to gauze, when the prose you still owe the day" />
        </div>
      </div>

      {/* chord callout */}
      <div className="absolute -right-2 -top-4 flex rotate-2 items-center gap-2.5 rounded-xl bg-ink px-3 py-2 text-paper shadow-[0_18px_40px_-12px_rgba(26,23,20,0.45)] sm:-right-6">
        <Kbd keys={["cmd", "alt", "shift", "S"]} className="text-[0.8rem]" />
        <span className="font-display text-[0.9rem] tracking-tight">read it</span>
      </div>
    </div>
  );
}
