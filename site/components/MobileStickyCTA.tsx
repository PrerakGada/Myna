"use client";

import { useEffect, useState } from "react";

/**
 * Pinned mobile-only install pill that fades in after the user scrolls
 * past the hero. Tucked above the home-indicator with safe-area padding.
 */
export function MobileStickyCTA() {
  const [visible, setVisible] = useState(false);
  const [past, setPast] = useState(false);

  useEffect(() => {
    const onScroll = () => {
      const y = window.scrollY;
      const h = window.innerHeight;
      setVisible(y > h * 0.7);
      // hide once we're inside the install section so it doesn't double up
      const install = document.getElementById("install");
      if (install) {
        const top = install.getBoundingClientRect().top;
        setPast(top < h * 0.7);
      }
    };
    onScroll();
    window.addEventListener("scroll", onScroll, { passive: true });
    return () => window.removeEventListener("scroll", onScroll);
  }, []);

  const show = visible && !past;

  return (
    <div
      aria-hidden={!show}
      className={`md:hidden fixed left-1/2 -translate-x-1/2 bottom-4 z-40 safe-bottom transition-all duration-300 ${
        show ? "opacity-100 translate-y-0 pointer-events-auto" : "opacity-0 translate-y-3 pointer-events-none"
      }`}
    >
      <a
        href="#install"
        className="inline-flex items-center gap-2 rounded-full bg-ink text-paper px-5 py-3 font-display text-[0.98rem] shadow-[0_18px_36px_-8px_rgba(26,23,20,0.55)]"
      >
        <span className="relative flex h-2 w-2">
          <span className="absolute inset-0 rounded-full bg-teal-glow animate-pulse-slow"/>
          <span className="relative rounded-full bg-teal-glow h-2 w-2"/>
        </span>
        Install Myna
        <svg width="14" height="14" viewBox="0 0 14 14" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" aria-hidden="true">
          <path d="M3 7h8M8 4l3 3-3 3"/>
        </svg>
      </a>
    </div>
  );
}
