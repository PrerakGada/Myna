import type { Config } from "tailwindcss";

const config: Config = {
  content: ["./app/**/*.{ts,tsx}", "./components/**/*.{ts,tsx}"],
  theme: {
    extend: {
      colors: {
        // Warm Reading Room palette
        paper: {
          DEFAULT: "#F5EFE2", // cream paper
          deep: "#EFE6D2", // deeper cream
          warm: "#FBF6E9", // warmest highlight
        },
        ink: {
          DEFAULT: "#1A1714", // warm near-black
          soft: "#3A332A",
          muted: "#6B5F4F",
          faint: "#A89880",
        },
        teal: {
          // Myna sheen — the iridescent teal-green of an actual myna's neck feathers
          DEFAULT: "#0F6B5C",
          deep: "#0A4F44",
          bright: "#1A9985",
          glow: "#3FBFA8",
        },
        rust: "#B65A3C", // dried-ink accent for highlights
      },
      fontFamily: {
        display: ["var(--font-fraunces)", "Georgia", "serif"],
        body: ["var(--font-newsreader)", "Georgia", "serif"],
        mono: ["var(--font-jetbrains)", "ui-monospace", "monospace"],
      },
      fontSize: {
        // Mobile-first display scale — bumped up only at md+
        "display-xl": ["clamp(2.5rem, 9vw, 6.5rem)", { lineHeight: "0.95", letterSpacing: "-0.03em" }],
        "display-lg": ["clamp(2rem, 6vw, 4rem)", { lineHeight: "1.02", letterSpacing: "-0.025em" }],
        "display-md": ["clamp(1.5rem, 4vw, 2.5rem)", { lineHeight: "1.1", letterSpacing: "-0.02em" }],
      },
      animation: {
        "wave-1": "wave 1.4s ease-in-out infinite",
        "wave-2": "wave 1.4s ease-in-out infinite 0.15s",
        "wave-3": "wave 1.4s ease-in-out infinite 0.3s",
        "wave-4": "wave 1.4s ease-in-out infinite 0.45s",
        "wave-5": "wave 1.4s ease-in-out infinite 0.6s",
        "wave-slow-1": "wave 2.6s ease-in-out infinite",
        "wave-slow-2": "wave 2.6s ease-in-out infinite 0.3s",
        "wave-slow-3": "wave 2.6s ease-in-out infinite 0.6s",
        "fade-up": "fadeUp 0.8s cubic-bezier(0.2, 0.6, 0.2, 1) both",
        "fade-in": "fadeIn 1.2s ease-out both",
        "marquee": "marquee 40s linear infinite",
        "pulse-slow": "pulseSlow 4s ease-in-out infinite",
        "shimmer": "shimmer 3s ease-in-out infinite",
      },
      keyframes: {
        wave: {
          "0%, 100%": { transform: "scaleY(0.35)" },
          "50%": { transform: "scaleY(1)" },
        },
        fadeUp: {
          "0%": { opacity: "0", transform: "translateY(24px)" },
          "100%": { opacity: "1", transform: "translateY(0)" },
        },
        fadeIn: {
          "0%": { opacity: "0" },
          "100%": { opacity: "1" },
        },
        marquee: {
          "0%": { transform: "translateX(0)" },
          "100%": { transform: "translateX(-50%)" },
        },
        pulseSlow: {
          "0%, 100%": { opacity: "0.4" },
          "50%": { opacity: "0.8" },
        },
        shimmer: {
          "0%, 100%": { backgroundPosition: "0% 50%" },
          "50%": { backgroundPosition: "100% 50%" },
        },
      },
      boxShadow: {
        page: "0 1px 0 rgba(26, 23, 20, 0.04), 0 24px 60px -20px rgba(26, 23, 20, 0.18)",
        soft: "0 1px 2px rgba(26, 23, 20, 0.06), 0 8px 24px -8px rgba(26, 23, 20, 0.12)",
        chip: "inset 0 0 0 1px rgba(26, 23, 20, 0.08), 0 1px 0 rgba(255, 255, 255, 0.6)",
      },
    },
  },
  plugins: [],
};

export default config;
