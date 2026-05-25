type Props = { keys: string[]; className?: string };

const SYMBOL: Record<string, string> = {
  cmd: "⌘",
  command: "⌘",
  alt: "⌥",
  option: "⌥",
  opt: "⌥",
  shift: "⇧",
  ctrl: "⌃",
  control: "⌃",
  return: "↩",
  enter: "↩",
  esc: "⎋",
  tab: "⇥",
  space: "Space",
  delete: "⌫",
  backspace: "⌫",
  up: "↑",
  down: "↓",
  left: "←",
  right: "→",
};

export function Kbd({ keys, className }: Props) {
  return (
    <span className={`inline-flex items-center gap-[3px] ${className ?? ""}`}>
      {keys.map((k, i) => {
        const lower = k.toLowerCase();
        const display = SYMBOL[lower] ?? k.toUpperCase();
        return (
          <kbd key={i} className="kbd">
            {display}
          </kbd>
        );
      })}
    </span>
  );
}
