type Props = { className?: string; size?: number };

/**
 * Hand-drawn myna bird mark — used in the nav, hero corner, and footer.
 * The myna is a small black-bodied South Asian bird with a striking
 * yellow ring around the eye and an orange-yellow beak. Its neck has a
 * faint iridescent teal sheen — the inspiration for our accent color.
 */
export function MynaMark({ className, size = 28 }: Props) {
  return (
    <svg
      viewBox="0 0 64 64"
      width={size}
      height={size}
      fill="none"
      className={className}
      aria-hidden="true"
    >
      {/* body */}
      <path
        d="M16 42c0-12 8-20 18-20 6 0 10 2 13 6l-3 2c-1 5-5 9-10 11l-2 9h-6l1-9c-5-1-9-3-11-5l0 6h-3l3-3v3z"
        fill="#1A1714"
      />
      {/* teal neck sheen */}
      <path
        d="M30 30c4 1 7 3 9 6"
        stroke="#0F6B5C"
        strokeWidth="1.6"
        strokeLinecap="round"
        fill="none"
        opacity="0.85"
      />
      {/* yellow eye ring */}
      <circle cx="38" cy="29" r="2.2" fill="#1A1714" />
      <circle cx="38" cy="29" r="2.2" fill="none" stroke="#E5B53C" strokeWidth="1.2" />
      <circle cx="38.4" cy="28.6" r="0.7" fill="#F5EFE2" />
      {/* beak */}
      <path d="M44 27.5l6-2-1 4-5 1z" fill="#D97A2E" />
      {/* yellow wattle */}
      <path d="M40 23l3-3 1 2-3 2z" fill="#E5B53C" opacity="0.9" />
    </svg>
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
