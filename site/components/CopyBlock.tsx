"use client";

import { useState } from "react";

type Line = { prompt?: boolean; text: string; comment?: boolean };

type Props = {
  lines: Line[];
  className?: string;
  label?: string;
};

export function CopyBlock({ lines, className, label }: Props) {
  const [copied, setCopied] = useState(false);

  const handleCopy = async () => {
    const text = lines
      .map((l) => (l.comment ? `# ${l.text}` : l.prompt ? `$ ${l.text}` : l.text))
      .join("\n");
    try {
      await navigator.clipboard.writeText(text);
      setCopied(true);
      setTimeout(() => setCopied(false), 1800);
    } catch {
      /* ignore */
    }
  };

  return (
    <div className={`relative ${className ?? ""}`}>
      {label && (
        <div className="flex items-center justify-between px-1 pb-2">
          <span className="font-mono text-[0.72rem] uppercase tracking-[0.18em] text-ink-muted">
            {label}
          </span>
          <button
            type="button"
            onClick={handleCopy}
            className="font-mono text-[0.72rem] uppercase tracking-[0.18em] text-ink-muted hover:text-teal transition-colors px-2 py-1 -mr-1"
          >
            {copied ? "copied ✓" : "copy"}
          </button>
        </div>
      )}
      <div className="code-block relative">
        {!label && (
          <button
            type="button"
            onClick={handleCopy}
            aria-label="Copy to clipboard"
            className="absolute top-2.5 right-2.5 font-mono text-[0.7rem] uppercase tracking-[0.15em] text-paper/45 hover:text-teal-glow transition-colors px-2.5 py-1.5 rounded-md bg-paper/5 hover:bg-paper/10"
          >
            {copied ? "copied ✓" : "copy"}
          </button>
        )}
        {lines.map((l, i) => (
          <div key={i} className="leading-relaxed">
            {l.comment ? (
              <span className="comment">{`# ${l.text}`}</span>
            ) : l.prompt ? (
              <>
                <span className="prompt select-none">$ </span>
                <span>{l.text}</span>
              </>
            ) : (
              <span>{l.text}</span>
            )}
          </div>
        ))}
      </div>
    </div>
  );
}
