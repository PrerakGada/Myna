import {
  ChevronGlyph,
  DocGlyph,
  DownloadGlyph,
  GearGlyph,
  MAC_ACCENT,
  PauseGlyph,
  PlayGlyph,
  PowerGlyph,
  RestartGlyph,
  SeekGlyph,
  SparkleGlyph,
  StopGlyph,
  SYSTEM_FONT,
} from "./Glyphs";
import { MynaMark } from "../MynaMark";

/**
 * A recreation of the menu-bar popover (apps/macos/Sources/MenuBar/
 * MenuBarView.swift): header, the Now Playing card, the collapsible Voice /
 * Speed / Claude Code / Recent sections, and the footer. Sized to the real
 * 360 pt popover and its PopoverDesign tokens.
 */
export function PopoverMock({ className }: { className?: string }) {
  return (
    <div
      className={`w-full max-w-[360px] rounded-[12px] bg-[#0A0A0C] px-[14px] py-3 text-white/95 shadow-[0_40px_80px_-24px_rgba(12,10,8,0.65)] ring-1 ring-white/[0.08] ${className ?? ""}`}
      style={{ fontFamily: SYSTEM_FONT }}
    >
      <div className="flex flex-col gap-3">
        {/* header */}
        <div className="flex items-center gap-2">
          <MynaMark size={28} />
          <span className="text-[14px] font-semibold">Myna</span>
          <span className="text-[11px] text-white/55">v0.5.1</span>
          <span className="flex-1" />
          <span className="h-1.5 w-1.5 rounded-full bg-[#4CD964]" />
          <span className="text-[11px] text-white/55">speaking</span>
        </div>

        {/* now playing */}
        <div className="rounded-[8px] border border-white/[0.06] bg-white/[0.04] p-3">
          <div className="flex items-center gap-1.5">
            <span className="h-1.5 w-1.5 rounded-full bg-[#4CD964]" />
            <span className="text-[11px] font-medium uppercase tracking-[0.04em] text-white/55">Now playing</span>
          </div>
          <div className="mt-2 text-[17px] font-semibold leading-snug">The quiet case for reading aloud</div>
          <div className="mt-1 text-[11px] text-white/55">af_heart · 1.0x · 0:42 / 2:18</div>
          <div className="mt-2.5 h-[3px] rounded-full bg-white/[0.08]">
            <div className="h-full w-[31%] rounded-full" style={{ background: MAC_ACCENT }} />
          </div>
          <div className="mt-3 grid grid-cols-4 gap-1.5">
            <Transport label="Back 15s" icon={<SeekGlyph seconds={15} direction="back" size={15} />} />
            <Transport label="Pause" icon={<PauseGlyph size={15} />} emphasised />
            <Transport label="Stop" icon={<StopGlyph size={13} />} />
            <Transport label="Skip 15s" icon={<SeekGlyph seconds={15} direction="forward" size={15} />} />
          </div>
        </div>

        <Section title="Voice" trailing="Heart (female)" />
        <Section title="Speed" trailing="1×" />

        <div className="flex flex-col gap-1.5">
          <Section title="Claude Code" trailing="2" open />
          <ClaudeCard
            project="myna"
            color="#2BB4B0"
            age="just now"
            text="Wired dmgbuild into the release workflow; the disk image now opens on its install stage."
          />
          <ClaudeCard
            project="landing-page"
            color="#7B5BFF"
            age="3m ago"
            text="Rewrote the install section and pointed /download at the latest release."
          />
        </div>

        <Section title="Recent" trailing="5" />

        <div className="-mx-[14px] h-px bg-white/[0.08]" />

        <div className="grid grid-cols-6 text-white/70">
          <Footer icon={<GearGlyph size={14} />} label="Settings" />
          <Footer icon={<SparkleGlyph size={14} />} label="What's New" />
          <Footer icon={<DownloadGlyph size={14} />} label="Updates" />
          <Footer icon={<RestartGlyph size={14} />} label="Restart" />
          <Footer icon={<DocGlyph size={14} />} label="Logs" />
          <Footer icon={<PowerGlyph size={14} />} label="Quit" />
        </div>
      </div>
    </div>
  );
}

function Transport({ label, icon, emphasised = false }: { label: string; icon: React.ReactNode; emphasised?: boolean }) {
  return (
    <div
      className={`flex flex-col items-center justify-center gap-[3px] rounded-[6px] ${emphasised ? "h-11" : "h-10 self-center"}`}
      style={{ background: emphasised ? "rgba(10,132,255,0.15)" : "rgba(255,255,255,0.04)" }}
    >
      {icon}
      <span className="text-[9px] font-medium text-white/55">{label}</span>
    </div>
  );
}

function Section({ title, trailing, open = false }: { title: string; trailing: string; open?: boolean }) {
  return (
    <div className="flex items-center gap-1.5 px-0.5">
      <span className="text-[12.5px] font-semibold text-white/90">{title}</span>
      <span className="flex-1" />
      <span className="text-[11.5px] text-white/80">{trailing}</span>
      <ChevronGlyph open={open} size={12} className="text-white/45" />
    </div>
  );
}

function ClaudeCard({ project, color, age, text }: { project: string; color: string; age: string; text: string }) {
  return (
    <div className="rounded-[6px] bg-white/[0.04] p-2.5" style={{ boxShadow: `inset 0 0 0 1px ${color}40` }}>
      <div className="flex items-baseline gap-1.5">
        <span className="h-2 w-2 rounded-full" style={{ background: color }} />
        <span className="text-[11px] font-semibold">{project}</span>
        <span className="text-[11px] text-white/55">· {age}</span>
      </div>
      <p className="mt-1.5 line-clamp-2 text-[12px] leading-snug text-white/85">{text}</p>
      <div className="mt-2 flex gap-1.5">
        <span
          className="inline-flex items-center gap-1 rounded-[5px] px-2 py-[3px] text-[11px] font-medium"
          style={{ color, background: `${color}26`, boxShadow: `inset 0 0 0 1px ${color}66` }}
        >
          <PlayGlyph size={9} /> Play
        </span>
        <span className="inline-flex items-center gap-1 rounded-[5px] bg-white/[0.04] px-2 py-[3px] text-[11px] font-medium text-white/85 ring-1 ring-inset ring-white/10">
          × Dismiss
        </span>
      </div>
    </div>
  );
}

function Footer({ icon, label }: { icon: React.ReactNode; label: string }) {
  return (
    <div className="flex flex-col items-center gap-1 py-0.5">
      {icon}
      <span className="whitespace-nowrap text-[8.5px] text-white/50">{label}</span>
    </div>
  );
}
