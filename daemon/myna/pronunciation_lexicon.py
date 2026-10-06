"""The starter pronunciation list: tech words the voice engines get wrong.

Every entry here fixes a real mispronunciation. Each was checked against
Kokoro's own grapheme-to-phoneme step (misaki 0.7.4 with its espeak
fallback, as mlx-audio 0.5.7 runs it), and each respelling was checked the
same way to produce the intended sounds. Words Kokoro already says well
are left out on purpose: nginx ("engine x"), SQL ("sequel"), macOS, iOS,
GIF (hard g, the majority reading; add "GIF → jif" if you prefer), CLI,
GUI, npm, pnpm, Xcode, GitHub, AWS, UI/UX, URL, API, OAuth, SaaS, sudo,
regex, Kubernetes, Docker, JSX, curl, …

Matching is case-insensitive and whole-word, so an entry must not be an
ordinary English word with another meaning ("LaTeX" would turn "latex
gloves" into "lay tech gloves", so it isn't here).

`heard` records what the engine said before the fix (misaki phonemes,
roughly spelled out) so the list can be re-checked when the engines
change. The user can switch off any entry, or the whole list, and add
their own; a user entry for the same word wins.
"""

from __future__ import annotations

STARTER: tuple[dict, ...] = (
    # Said nothing at all.
    {"word": "gRPC", "say": "G R P C", "heard": "(silence)"},
    {"word": "GraphQL", "say": "graph Q L", "heard": "(silence)"},
    {"word": "RabbitMQ", "say": "rabbit M Q", "heard": "(silence)"},
    {"word": "MongoDB", "say": "mongo D B", "heard": "(silence)"},
    {"word": "a11y", "say": "eh eleven wye", "heard": "(silence)"},
    # Spelled out letter by letter.
    {"word": "JSON", "say": "jay son", "heard": "J S O N"},
    {"word": "YAML", "say": "yammel", "heard": "Y A M L"},
    {"word": "TOML", "say": "tommel", "heard": "T O M L"},
    {"word": "README", "say": "read me", "heard": "R E A D M E"},
    {"word": "TODO", "say": "to do", "heard": "T O D O"},
    {"word": "WASM", "say": "wazzum", "heard": "W A S M"},
    {"word": "FLAC", "say": "flack", "heard": "F L A C"},
    {"word": "OGG", "say": "og", "heard": "O G G"},
    {"word": "EPUB", "say": "ee pub", "heard": "E P U B"},
    {"word": "DMARC", "say": "dee mark", "heard": "D M A R C"},
    {"word": "nginx", "say": "engine x", "heard": "N G I N X (in capitals)"},
    {"word": "cURL", "say": "curl", "heard": "C U R L"},
    # Mispronounced.
    {"word": "kubectl", "say": "cube control", "heard": "kyoo-bect-l"},
    {"word": "async", "say": "eh sink", "heard": "uh-SINK"},
    {"word": "enum", "say": "ee num", "heard": "in-UM"},
    {"word": "enums", "say": "ee nums", "heard": "in-UMZ"},
    {"word": "stdin", "say": "standard in", "heard": "S T d-in"},
    {"word": "stdout", "say": "standard out", "heard": "S T d-out"},
    {"word": "stderr", "say": "standard error", "heard": "S T d-air"},
    {"word": "sed", "say": "sedd", "heard": "est"},
    {"word": "mkdir", "say": "make dir", "heard": "M K dire"},
    {"word": "rustc", "say": "rust C", "heard": "rust-k"},
    {"word": "launchd", "say": "launch D", "heard": "launched"},
    {"word": "launchctl", "say": "launch control", "heard": "launch-k-tl"},
    {"word": "systemd", "say": "system D", "heard": "systemed"},
    {"word": "Golang", "say": "go lang", "heard": "GAH-lang"},
    {"word": "PyPI", "say": "pie P I", "heard": "pie pie"},
    {"word": "pytest", "say": "pie test", "heard": "PIE-tist"},
    {"word": "Jupyter", "say": "Jupiter", "heard": "JUP-eye-ter"},
    {"word": "Deno", "say": "dee no", "heard": "dih-NO"},
    {"word": "Vite", "say": "veet", "heard": "vite (as in kite)"},
    {"word": "Redis", "say": "red iss", "heard": "rih-DEEZ"},
    {"word": "Postgres", "say": "post gress", "heard": "post-gurz"},
    {"word": "PostgreSQL", "say": "post gress Q L", "heard": "post-gurr S Q L"},
    {"word": "SQLite", "say": "sequel light", "heard": "S Q lite"},
    {"word": "serde", "say": "ser dee", "heard": "surd"},
    {"word": "ESLint", "say": "E S lint", "heard": "ease lint"},
    {"word": "PaaS", "say": "pass", "heard": "pah S"},
    {"word": "IPv4", "say": "I P v4", "heard": "ipv four"},
    {"word": "IPv6", "say": "I P v6", "heard": "ipv six"},
    {"word": "2FA", "say": "two F A", "heard": "two fah"},
    {"word": "visionOS", "say": "vision O S", "heard": "vision-oss"},
    # This app.
    {"word": "Myna", "say": "Mynah", "heard": "MEE-nuh"},
)
