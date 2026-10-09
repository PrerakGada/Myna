"use client";

import { useState } from "react";
import { CopyBlock } from "@/components/CopyBlock";
import { HOMEBREW_LINES } from "@/lib/download";

declare global {
  interface Window {
    productTracker?: unknown;
  }
}

type Props = {
  /** Classes for the wrapper (spacing). */
  className?: string;
  /** Extra classes for the button, e.g. light-on-dark overrides of btn-ghost. */
  buttonClassName?: string;
  /** A one-line hint shown beside the button, e.g. where the commands appear. */
  hint?: React.ReactNode;
};

/**
 * "Install with Homebrew". The shared tracker (app/layout.tsx) binds every
 * element marked data-pt-command: a click opens the download form, and the
 * commands from the tag's data-command appear only after it is filled in or
 * skipped. If the tracker script never loaded (an ad blocker, offline), the
 * button reveals the commands right here instead, so it is never dead.
 */
export function HomebrewButton({ className, buttonClassName, hint }: Props) {
  const [revealed, setRevealed] = useState(false);

  return (
    <div className={className}>
      <div className="flex flex-wrap items-center gap-x-5 gap-y-3">
        <button
          type="button"
          data-pt-command=""
          onClick={() => {
            if (!window.productTracker) setRevealed(true);
          }}
          className={`btn-ghost ${buttonClassName ?? ""}`}
        >
          <svg
            width="15"
            height="15"
            viewBox="0 0 16 16"
            fill="none"
            stroke="currentColor"
            strokeWidth="1.4"
            strokeLinecap="round"
            strokeLinejoin="round"
            aria-hidden="true"
          >
            <rect x="1.5" y="2.5" width="13" height="11" rx="2" />
            <path d="M4.5 6.5 6.5 8l-2 1.5M8.5 10h3" />
          </svg>
          <span>Install with Homebrew</span>
        </button>
        {hint && !revealed ? hint : null}
      </div>
      {revealed && <CopyBlock className="mt-5" lines={HOMEBREW_LINES.map((text) => ({ prompt: true, text }))} />}
    </div>
  );
}
