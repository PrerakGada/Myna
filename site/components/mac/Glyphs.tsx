/**
 * Small stand-ins for the SF Symbols Myna's UI uses, drawn as inline SVG so
 * the recreated app surfaces render the same in every browser.
 */

export const SYSTEM_FONT =
  "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Helvetica Neue', system-ui, sans-serif";

/** macOS's default accent. Myna's pill and popover follow the user's accent colour. */
export const MAC_ACCENT = "#0A84FF";

type GlyphProps = { size?: number; className?: string };

function Svg({ size = 16, className, children, fill = "none" }: GlyphProps & { children: React.ReactNode; fill?: string }) {
  return (
    <svg
      viewBox="0 0 24 24"
      width={size}
      height={size}
      fill={fill}
      stroke={fill === "none" ? "currentColor" : "none"}
      strokeWidth={1.8}
      strokeLinecap="round"
      strokeLinejoin="round"
      className={className}
      aria-hidden="true"
    >
      {children}
    </svg>
  );
}

export function BirdGlyph({ size = 16, className }: GlyphProps) {
  return (
    <span
      aria-hidden="true"
      className={`inline-block shrink-0 ${className ?? ""}`}
      style={{
        width: size,
        height: size,
        backgroundColor: "currentColor",
        mask: 'url("/brand/myna-filled.svg") center / contain no-repeat',
        WebkitMask: 'url("/brand/myna-filled.svg") center / contain no-repeat',
      }}
    />
  );
}

export function PlayGlyph(p: GlyphProps) {
  return (
    <Svg {...p} fill="currentColor">
      <path d="M7.5 5.2v13.6c0 .8.9 1.3 1.6.9l10.7-6.8c.6-.4.6-1.3 0-1.7L9.1 4.3c-.7-.4-1.6.1-1.6.9Z" />
    </Svg>
  );
}

export function PauseGlyph(p: GlyphProps) {
  return (
    <Svg {...p} fill="currentColor">
      <rect x="6" y="4.5" width="4.2" height="15" rx="1.2" />
      <rect x="13.8" y="4.5" width="4.2" height="15" rx="1.2" />
    </Svg>
  );
}

export function StopGlyph(p: GlyphProps) {
  return (
    <Svg {...p} fill="currentColor">
      <rect x="5.5" y="5.5" width="13" height="13" rx="2.2" />
    </Svg>
  );
}

export function CloseGlyph(p: GlyphProps) {
  return (
    <Svg {...p}>
      <path d="M6.5 6.5l11 11M17.5 6.5l-11 11" />
    </Svg>
  );
}

export function ChevronGlyph({ open = false, ...p }: GlyphProps & { open?: boolean }) {
  return (
    <Svg {...p}>
      <path d={open ? "M6.5 9.5 12 15l5.5-5.5" : "M9.5 6.5 15 12l-5.5 5.5"} />
    </Svg>
  );
}

/** gobackward.N / goforward.N */
export function SeekGlyph({ seconds, direction, size = 16, className }: GlyphProps & { seconds: number; direction: "back" | "forward" }) {
  const back = direction === "back";
  return (
    <svg viewBox="0 0 24 24" width={size} height={size} fill="none" className={className} aria-hidden="true">
      <path
        d={back ? "M6.2 7.4A8.2 8.2 0 1 1 3.8 12.6" : "M17.8 7.4A8.2 8.2 0 1 0 20.2 12.6"}
        stroke="currentColor"
        strokeWidth={1.7}
        strokeLinecap="round"
      />
      <path
        d={back ? "M6.6 3.6 6.2 7.4 10 7.9" : "M17.4 3.6 17.8 7.4 14 7.9"}
        stroke="currentColor"
        strokeWidth={1.7}
        strokeLinecap="round"
        strokeLinejoin="round"
      />
      <text x="12" y="15.4" textAnchor="middle" fontSize="7.4" fontWeight={700} fill="currentColor" fontFamily={SYSTEM_FONT}>
        {seconds}
      </text>
    </svg>
  );
}

export function GearGlyph(p: GlyphProps) {
  return (
    <Svg {...p}>
      <circle cx="12" cy="12" r="3.2" />
      <path d="M12 3.2v2.2M12 18.6v2.2M3.2 12h2.2M18.6 12h2.2M5.8 5.8l1.5 1.5M16.7 16.7l1.5 1.5M5.8 18.2l1.5-1.5M16.7 7.3l1.5-1.5" />
    </Svg>
  );
}

export function SparkleGlyph(p: GlyphProps) {
  return (
    <Svg {...p}>
      <path d="M12 3.5c.6 3.9 2.6 5.9 6.5 6.5-3.9.6-5.9 2.6-6.5 6.5-.6-3.9-2.6-5.9-6.5-6.5 3.9-.6 5.9-2.6 6.5-6.5Z" />
      <path d="M18.5 15.5c.3 1.6 1.1 2.4 2.7 2.7-1.6.3-2.4 1.1-2.7 2.7-.3-1.6-1.1-2.4-2.7-2.7 1.6-.3 2.4-1.1 2.7-2.7Z" />
    </Svg>
  );
}

export function DownloadGlyph(p: GlyphProps) {
  return (
    <Svg {...p}>
      <circle cx="12" cy="12" r="8.5" />
      <path d="M12 7.5v8M8.8 12.6 12 15.8l3.2-3.2" />
    </Svg>
  );
}

export function RestartGlyph(p: GlyphProps) {
  return (
    <Svg {...p}>
      <path d="M19.5 12a7.5 7.5 0 1 1-2.2-5.3" />
      <path d="M19.8 4.2v3.6h-3.6" />
    </Svg>
  );
}

export function DocGlyph(p: GlyphProps) {
  return (
    <Svg {...p}>
      <path d="M7 3.5h6.5L18 8v12.5H7Z" />
      <path d="M13.5 3.5V8H18M9.8 12.5h5.4M9.8 16h5.4" />
    </Svg>
  );
}

export function PowerGlyph(p: GlyphProps) {
  return (
    <Svg {...p}>
      <path d="M12 3.5v8" />
      <path d="M7.2 6.6a7.5 7.5 0 1 0 9.6 0" />
    </Svg>
  );
}

export function CheckCircleGlyph(p: GlyphProps) {
  return (
    <Svg {...p} fill="currentColor">
      <path d="M12 2.5a9.5 9.5 0 1 0 0 19 9.5 9.5 0 0 0 0-19Zm4.6 6.9-5.5 6.1a1 1 0 0 1-1.5 0l-2.3-2.5a1 1 0 1 1 1.5-1.4l1.5 1.7 4.8-5.3a1 1 0 1 1 1.5 1.4Z" />
    </Svg>
  );
}
