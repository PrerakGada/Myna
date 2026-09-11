/* eslint-disable @next/next/no-img-element */
import { CheckCircleGlyph, MAC_ACCENT, SYSTEM_FONT } from "./Glyphs";

/**
 * A recreation of Myna's first-launch installer, mid-install
 * (apps/macos/Sources/Setup/SetupView.swift).
 */
type Status = "done" | "running" | "pending";

const STEPS: { title: string; detail: string; status: Status; size?: string }[] = [
  { title: "Check this Mac", detail: "macOS 26.0", status: "done" },
  { title: "Python runtime", detail: "Python 3.13", status: "done" },
  { title: "Voice engine", detail: "Installing the voice engine — about 600 MB the first time…", status: "running", size: "~600 MB" },
  { title: "Background service", detail: "Keeps the voice ready and starts when you log in", status: "pending" },
  { title: "Kokoro voice", detail: "The voice model, downloaded once", status: "pending", size: "~370 MB" },
  { title: "Claude Code", detail: "Reads finished Claude replies aloud, if you use it", status: "pending" },
];

export function InstallerMock({ className }: { className?: string }) {
  return (
    <div
      className={`w-full max-w-[520px] overflow-hidden rounded-[14px] bg-[#0A0A0C] text-white shadow-[0_40px_90px_-30px_rgba(0,0,0,0.7)] ring-1 ring-white/[0.1] ${className ?? ""}`}
      style={{ fontFamily: SYSTEM_FONT }}
    >
      <div className="relative px-6 pb-5 pt-9" style={{ background: "radial-gradient(ellipse 80% 60% at 0% 0%, rgba(10,132,255,0.12), transparent 70%)" }}>
        <span className="absolute left-3.5 top-3 h-3 w-3 rounded-full bg-[#FF5F57]" />
        <div className="flex items-center gap-3.5">
          <img src="/app-icon.png" alt="" width={52} height={52} className="h-[52px] w-[52px]" />
          <div>
            <div className="text-[19px] font-semibold">Setting up Myna</div>
            <div className="mt-0.5 text-[12px] text-white/55">This takes a few minutes. You can keep working while it runs.</div>
          </div>
        </div>

        <div className="mt-5 rounded-[12px] border border-white/[0.06] bg-white/[0.04] py-1">
          {STEPS.map((step, i) => (
            <div key={step.title}>
              <div className="flex items-center gap-3 px-3.5 py-2">
                <span className="inline-flex h-5 w-5 shrink-0 items-center justify-center">
                  {step.status === "done" && <CheckCircleGlyph size={17} className="text-[#4CD964]" />}
                  {step.status === "running" && (
                    <span className="h-[14px] w-[14px] animate-spin rounded-full border-2 border-white/20" style={{ borderTopColor: "rgba(255,255,255,0.85)" }} />
                  )}
                  {step.status === "pending" && <span className="h-[13px] w-[13px] rounded-full border-[1.5px] border-white/25" />}
                </span>
                <div className="min-w-0 flex-1">
                  <div className={`text-[12.5px] font-medium ${step.status === "pending" ? "text-white/70" : ""}`}>{step.title}</div>
                  <div className="truncate text-[11px] text-white/55">{step.detail}</div>
                </div>
                {step.size && step.status !== "done" && (
                  <span className="text-[10.5px] tabular-nums text-white/50">{step.size}</span>
                )}
              </div>
              {i < STEPS.length - 1 && <div className="ml-[46px] h-px bg-white/[0.06]" />}
            </div>
          ))}
        </div>

        <div className="mt-4 flex items-center gap-3">
          <span className="text-[11px] tabular-nums text-white/55">Elapsed 1:24</span>
          <span className="flex-1" />
          <span className="text-[11.5px] text-white/55">Show details</span>
          <span className="rounded-full px-4 py-1.5 text-[12px] font-semibold text-white/70" style={{ background: `${MAC_ACCENT}66` }}>
            Installing…
          </span>
        </div>
      </div>
    </div>
  );
}
