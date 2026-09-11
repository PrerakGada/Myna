/* eslint-disable @next/next/no-img-element */
type Props = { className?: string; size?: number };

/**
 * Myna's mark — the app icon's rounded square (public/favicon.svg, cropped
 * from dist/brand/app-icon.svg). Used in the nav and footer.
 */
export function MynaMark({ className, size = 28 }: Props) {
  return (
    <img
      src="/favicon.svg"
      width={size}
      height={size}
      alt=""
      aria-hidden="true"
      className={`shrink-0 rounded-[22%] shadow-[0_1px_2px_rgba(26,23,20,0.18)] ${className ?? ""}`}
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
