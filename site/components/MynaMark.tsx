/* eslint-disable @next/next/no-img-element */
type Props = { className?: string; size?: number };

/**
 * The selected full-bird clay icon. Monochrome UI glyphs live in mac/Glyphs
 * and share the native app's exports.
 */
export function MynaMark({ className, size = 28 }: Props) {
  return (
    <img
      src="/app-icon.png"
      width={size}
      height={size}
      alt=""
      aria-hidden="true"
      className={`shrink-0 ${className ?? ""}`}
      style={{ width: size, height: size }}
    />
  );
}

/**
 * Just the wordmark text — used inline with the mark.
 */
export function MynaWordmark({ className }: { className?: string }) {
  return (
    <span
      className={`font-display text-[1.35rem] tracking-tight ${className ?? ""}`}
      style={{ fontWeight: 500 }}
    >
      Myna
    </span>
  );
}
