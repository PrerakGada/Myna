"use client";

import { useEffect, useState } from "react";

type Props = {
  bars?: number;
  className?: string;
  /** Speed multiplier — 0.5 = languid, 1.5 = quick. */
  pace?: number;
  /** Maximum bar height (px). */
  height?: number;
  /** Minimum bar height (px). */
  min?: number;
  /** Width of each bar (px). */
  barWidth?: number;
  /** Gap between bars (px). */
  gap?: number;
};

/**
 * A warm, organic-feeling soundwave. Each bar pulses independently
 * with a hand-tuned set of delays and durations so the wave never
 * looks too "synced" — it should feel alive, like a voice mid-sentence.
 *
 * Pure CSS animation, no rAF — keeps it cheap on mobile.
 */
export function Soundwave({
  bars = 28,
  className,
  pace = 1,
  height = 56,
  min = 6,
  barWidth = 3,
  gap = 6,
}: Props) {
  // Deterministic pseudo-random profile so SSR and client match.
  // Values rounded to 2 decimals so the serialised HTML and re-parsed
  // inline styles are byte-identical between server and client.
  const [profile] = useState(() => {
    const seed = 7;
    const round = (x: number) => Math.round(x * 100) / 100;
    const out: { delay: number; dur: number; amp: number }[] = [];
    for (let i = 0; i < bars; i++) {
      const n = Math.sin(i * 2.39 + seed) * 0.5 + 0.5;
      const m = Math.sin(i * 1.13 + seed * 0.7) * 0.5 + 0.5;
      out.push({
        delay: round(n * 1.6),
        dur: round(1.1 + m * 1.4),
        amp: round(0.35 + (1 - Math.abs(i - bars / 2) / (bars / 2)) * 0.65),
      });
    }
    return out;
  });

  return (
    <div
      className={`flex items-center ${className ?? ""}`}
      style={{ gap, height }}
      aria-hidden="true"
    >
      {profile.map((p, i) => (
        <span
          key={i}
          className="wave-bar"
          style={{
            width: barWidth,
            height,
            animationName: "wave",
            animationDuration: `${(p.dur / pace).toFixed(2)}s`,
            animationTimingFunction: "ease-in-out",
            animationDelay: `${p.delay.toFixed(2)}s`,
            animationIterationCount: "infinite",
            transform: `scaleY(${(p.amp * 0.4).toFixed(2)})`,
          }}
        />
      ))}
    </div>
  );
}

/**
 * A subtle, static "rest-state" waveform — used as decoration when
 * we don't want animation (e.g. respecting reduced-motion or in
 * static sections).
 */
export function StaticWave({
  className,
  bars = 40,
  height = 36,
}: {
  className?: string;
  bars?: number;
  height?: number;
}) {
  return (
    <svg
      viewBox={`0 0 ${bars * 6} ${height}`}
      className={className}
      preserveAspectRatio="none"
      aria-hidden="true"
    >
      {Array.from({ length: bars }).map((_, i) => {
        const n = Math.sin(i * 0.6) * 0.5 + Math.sin(i * 0.23) * 0.3 + 0.5;
        const h = Math.max(2, n * height * 0.9);
        return (
          <rect
            key={i}
            x={i * 6 + 1.5}
            y={(height - h) / 2}
            width={3}
            height={h}
            rx={1.5}
            fill="currentColor"
            opacity={0.55 + n * 0.45}
          />
        );
      })}
    </svg>
  );
}
