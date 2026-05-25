"use client";

import { useEffect, useState } from "react";
import { MynaMark, MynaWordmark } from "./MynaMark";
import { GitHubStarButton } from "./GitHubStar";

const SECTIONS = [
  { id: "features", label: "Features" },
  { id: "how", label: "How it works" },
  { id: "install", label: "Install" },
  { id: "faq", label: "FAQ" },
];

export function Nav({ starSlot }: { starSlot?: React.ReactNode }) {
  const [scrolled, setScrolled] = useState(false);
  const [menuOpen, setMenuOpen] = useState(false);

  useEffect(() => {
    const onScroll = () => setScrolled(window.scrollY > 12);
    onScroll();
    window.addEventListener("scroll", onScroll, { passive: true });
    return () => window.removeEventListener("scroll", onScroll);
  }, []);

  // Lock scroll while menu is open on mobile
  useEffect(() => {
    if (menuOpen) {
      document.body.style.overflow = "hidden";
    } else {
      document.body.style.overflow = "";
    }
    return () => { document.body.style.overflow = ""; };
  }, [menuOpen]);

  return (
    <>
      <header
        className={`safe-top fixed left-0 right-0 top-0 z-50 transition-all duration-300 ${
          scrolled
            ? "bg-paper/85 backdrop-blur-md shadow-[0_1px_0_rgba(26,23,20,0.06)]"
            : "bg-transparent"
        }`}
      >
        <div className="mx-auto flex max-w-6xl items-center justify-between px-5 py-3.5 sm:px-8">
          <a href="#top" className="flex items-center gap-2.5 -m-2 p-2" aria-label="Myna home">
            <MynaMark size={28} />
            <MynaWordmark />
          </a>

          <nav className="hidden items-center gap-7 md:flex" aria-label="Primary">
            {SECTIONS.map((s) => (
              <a
                key={s.id}
                href={`#${s.id}`}
                className="font-display text-[0.98rem] text-ink/80 transition-colors hover:text-ink"
              >
                {s.label}
              </a>
            ))}
          </nav>

          <div className="flex items-center gap-2">
            <div className="hidden sm:block">{starSlot}</div>
            <a
              href="#install"
              className="hidden md:inline-flex items-center rounded-full bg-ink px-4 py-2 font-display text-[0.95rem] text-paper hover:bg-ink-soft transition-colors"
            >
              Install
            </a>

            {/* Mobile menu toggle */}
            <button
              type="button"
              onClick={() => setMenuOpen((m) => !m)}
              aria-label={menuOpen ? "Close menu" : "Open menu"}
              aria-expanded={menuOpen}
              className="md:hidden inline-flex h-11 w-11 items-center justify-center rounded-full -mr-2"
            >
              <span className="relative block h-3.5 w-5">
                <span
                  className={`absolute left-0 right-0 h-[1.5px] bg-ink transition-all duration-300 ${
                    menuOpen ? "top-1.5 rotate-45" : "top-0"
                  }`}
                />
                <span
                  className={`absolute left-0 right-0 h-[1.5px] bg-ink transition-all duration-300 ${
                    menuOpen ? "top-1.5 -rotate-45" : "top-3"
                  }`}
                />
              </span>
            </button>
          </div>
        </div>
      </header>

      {/* Mobile drawer */}
      <div
        className={`fixed inset-0 z-40 transition-all duration-300 md:hidden ${
          menuOpen ? "pointer-events-auto opacity-100" : "pointer-events-none opacity-0"
        }`}
        aria-hidden={!menuOpen}
      >
        <div
          className="absolute inset-0 bg-ink/30 backdrop-blur-sm"
          onClick={() => setMenuOpen(false)}
        />
        <div
          className={`absolute right-0 top-0 h-full w-[78%] max-w-sm bg-paper-warm shadow-2xl transition-transform duration-300 safe-top ${
            menuOpen ? "translate-x-0" : "translate-x-full"
          }`}
        >
          <div className="flex flex-col gap-1 px-7 pt-24">
            {SECTIONS.map((s, i) => (
              <a
                key={s.id}
                href={`#${s.id}`}
                onClick={() => setMenuOpen(false)}
                className="font-display text-[1.7rem] py-2 text-ink hover:text-teal transition-colors"
                style={{
                  animation: menuOpen ? `fadeUp 0.5s ${0.1 + i * 0.05}s both` : "none",
                }}
              >
                {s.label}
              </a>
            ))}
            <div className="mt-6 flex flex-col gap-3">
              <a
                href="#install"
                onClick={() => setMenuOpen(false)}
                className="btn-primary w-full"
              >
                Install Myna
              </a>
              <a
                href="https://github.com/PrerakGada/myna"
                target="_blank"
                rel="noopener noreferrer"
                onClick={() => setMenuOpen(false)}
                className="btn-ghost w-full"
              >
                View on GitHub
              </a>
            </div>
          </div>
        </div>
      </div>
    </>
  );
}
