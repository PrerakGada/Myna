import { Soundwave } from "../Soundwave";
import {
  BirdGlyph,
  CloseGlyph,
  MAC_ACCENT,
  PauseGlyph,
  PlayGlyph,
  SeekGlyph,
  StopGlyph,
  SYSTEM_FONT,
} from "./Glyphs";

/**
 * A recreation of Myna's floating pill — the 340 pt mini-player that sits at
 * the bottom of the screen while Myna reads (apps/macos/Sources/FloatingPill/
 * PillView.swift). "playing" is the expanded player; "prompt" is the banner it
 * shows when a Claude Code session finishes.
 */
type Props = {
  variant?: "playing" | "prompt";
  headline?: string;
  prompt?: string;
  className?: string;
};

export function PillMock({
  variant = "playing",
  headline = "There is a particular hour of the afternoon when the screen",
  prompt = "Done. The pill now remembers where you left it on each display, and dragging it…",
  className,
}: Props) {
  const playing = variant === "playing";
  return (
    <div
      className={`w-[340px] max-w-full rounded-[18px] bg-[rgba(30,28,26,0.9)] px-[14px] py-3 text-white shadow-[0_30px_60px_-20px_rgba(12,10,8,0.6)] ring-1 ring-white/[0.08] backdrop-blur-xl ${className ?? ""}`}
      style={{ fontFamily: SYSTEM_FONT }}
    >
      {!playing && <PromptBanner text={prompt} />}

      <div className="flex items-center gap-2.5">
        <span
          className="inline-flex h-[30px] w-[30px] shrink-0 items-center justify-center rounded-full"
          style={{ background: `linear-gradient(180deg, ${MAC_ACCENT}, #0064E0)` }}
        >
          <BirdGlyph size={17} className="text-white" />
        </span>
        <div className="min-w-0 flex-1">
          <div className="truncate text-[13px] font-semibold leading-tight">{playing ? headline : "Myna"}</div>
          <div className="mt-1 flex items-center gap-1.5">
            <span className="rounded-full bg-white/[0.09] px-[7px] py-[1px] text-[10px] font-medium text-white/60">af_heart</span>
            {playing && <Soundwave bars={9} barWidth={2} gap={2} height={10} pace={1.1} className="text-white/70" />}
          </div>
        </div>
        <span className="inline-flex h-[22px] w-[22px] items-center justify-center text-white/50">
          <CloseGlyph size={11} />
        </span>
      </div>

      {playing && (
        <>
          <div className="mt-2.5 flex items-center gap-2">
            <span className="w-[34px] text-[10px] font-medium tabular-nums text-white/55">0:42</span>
            <div className="relative h-[4px] flex-1 rounded-full bg-white/[0.16]">
              <div className="absolute inset-y-0 left-0 w-[31%] rounded-full" style={{ background: MAC_ACCENT }} />
              <span className="absolute top-1/2 h-[11px] w-[11px] -translate-y-1/2 rounded-full bg-white shadow" style={{ left: "calc(31% - 5px)" }} />
            </div>
            <span className="w-[34px] text-right text-[10px] font-medium tabular-nums text-white/55">2:18</span>
          </div>
          <div className="mt-1.5 flex items-center gap-3 text-white/90">
            <span className="inline-flex h-7 w-7 items-center justify-center"><SeekGlyph seconds={10} direction="back" size={17} /></span>
            <span className="inline-flex h-7 w-7 items-center justify-center"><PauseGlyph size={17} /></span>
            <span className="inline-flex h-7 w-7 items-center justify-center"><SeekGlyph seconds={10} direction="forward" size={17} /></span>
            <span className="inline-flex h-7 w-7 items-center justify-center"><StopGlyph size={14} /></span>
            <span className="flex-1" />
            <span className="inline-flex h-[22px] min-w-[30px] items-center justify-center rounded-full bg-white/10 px-1.5 text-[11px] font-semibold tabular-nums">1.25×</span>
          </div>
        </>
      )}
    </div>
  );
}

function PromptBanner({ text }: { text: string }) {
  return (
    <div className="mb-2.5 border-b border-white/[0.08] pb-2.5">
      <div className="flex items-center gap-[7px]">
        <span className="h-1.5 w-1.5 rounded-full" style={{ background: MAC_ACCENT }} />
        <span className="text-[12px] font-semibold">New output ready</span>
      </div>
      <p className="mt-[5px] line-clamp-2 text-[11px] leading-snug text-white/60">{text}</p>
      <div className="mt-[7px] flex items-center gap-2">
        <span className="inline-flex items-center gap-1 rounded-full px-[11px] py-[4px] text-[11px] font-semibold text-white" style={{ background: MAC_ACCENT }}>
          <PlayGlyph size={10} /> Play
        </span>
        <span className="rounded-full bg-white/10 px-[11px] py-[4px] text-[11px] font-medium text-white/60">Dismiss</span>
      </div>
    </div>
  );
}

/** The collapsed pill: a short frosted bar that pulses while Myna works. */
export function PillBar({ className }: { className?: string }) {
  return (
    <span
      aria-hidden="true"
      className={`block h-[6px] w-[64px] rounded-full animate-pulse-slow ${className ?? ""}`}
      style={{ background: `linear-gradient(90deg, ${MAC_ACCENT}, #5AB0FF)` }}
    />
  );
}
