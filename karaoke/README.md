# MynaKaraoke

Floating karaoke ribbon sidecar for Myna. v0.2 Tier 1 — daemon spawns this
on the first karaoke event; it reads NDJSON over a Unix socket and renders
a translucent ribbon at the bottom of the screen.

## Build

```bash
swift build                    # debug
swift build -c release --arch arm64
bash build.sh                  # wraps into MynaKaraoke.app + signs if creds present
```

## Test

```bash
swift test                     # 26 tests, ~50ms total
swiftlint lint --config .swiftlint.yml
```

## Run standalone (for development)

```bash
# Pipe NDJSON test events into the sidecar:
rm -f /tmp/karaoke.sock
./MynaKaraoke.app/Contents/MacOS/MynaKaraoke --socket /tmp/karaoke.sock &
printf '%s\n' \
  '{"v":1,"type":"start","id":"u1","sentence":"Hello world","words":[{"i":0,"t":"Hello"},{"i":1,"t":"world"}],"estimatedDurationMs":1000,"voice":"af_heart"}' \
  '{"v":1,"type":"word","id":"u1","i":0,"tMs":0}' \
  '{"v":1,"type":"word","id":"u1","i":1,"tMs":500}' \
  '{"v":1,"type":"stop","id":"u1"}' \
  | nc -U /tmp/karaoke.sock
```

## Architecture

See `docs/v0.2-plan/02-karaoke-architecture.md` for the design brief and
`docs/native-app/sidecar-release.md` for the release flow.

- `MynaKaraokeCore` library — all logic (Protocol, Mailbox, LineBuffer,
  SocketListener, PanelController). Importable, testable.
- `MynaKaraoke` executable — main.swift AppDelegate + NSApplication bootstrap.

Wire protocol (Daemon → Sidecar, NDJSON, LOCKED — Track B must match):

| type | shape |
|---|---|
| `start` | `{"v":1,"type":"start","id":"...","sentence":"...","words":[{"i":N,"t":"..."},...],"estimatedDurationMs":N,"voice":"..."}` |
| `word` | `{"v":1,"type":"word","id":"...","i":N,"tMs":N}` |
| `pause` | `{"v":1,"type":"pause","id":"..."}` |
| `resume` | `{"v":1,"type":"resume","id":"...","tMs":N}` |
| `stop` | `{"v":1,"type":"stop","id":"..."}` |
| `config` | `{"v":1,"type":"config","fontSize":N,"position":"...","theme":"...","opacity":N}` |

Bundle ID: `dev.myna.karaoke` (shares the `dev.myna.*` prefix with the outer app at `dev.myna.app`).
Min macOS: 14.0 (Sonoma). arm64-only.
