# 🐢 Claude Usage Bar

**Stop tab-switching to check if you've hit your Claude limit.**
A native macOS menu-bar widget that shows your **Claude.ai session usage** — live % used, a countdown to reset, and a mood emoji that judges you accordingly.

```
☕ ▓▓░░░ 42% · 2h14m      ← lives quietly in your menu bar
```

😴 `<25%` → ☕ `<60%` → 😰 `<85%` → 🔥 `≥85%` — the emoji and color (green → orange → red) track your usage so you can tell how worried to be without reading a single number.

Click it for the full picture:

```
Session: 42% used
Remaining: 58%
Resets in 2h14m  (3:45 PM)
─────────────
Refresh now
Set session key…
Open usage page
Quit
```

## Why this exists

Anthropic's usage page is one tab-switch and one page-load away from an answer you want constantly: *"can I keep going, or am I about to get rate-limited mid-refactor?"* This puts that answer in your peripheral vision, permanently, for less RAM than a single Chrome tab.

## It's stupidly light

|                | This widget      | A single Chrome tab |
|----------------|------------------|----------------------|
| RAM            | ~40–50 MB        | 150–300 MB+          |
| Disk           | ~150 KB          | —                    |
| CPU (idle)     | ~0%              | ~0–1% (background JS)|
| Dependencies   | none — pure Swift + AppKit | — |

Written in Swift, no Python/Electron/venv, no third-party packages. One repaint every 30 seconds, one network fetch every 5 minutes. That's the entire runtime footprint.

## How it gets the data

Claude has no official public usage API, so this reads the same internal, cookie-authenticated endpoint the official **Settings → Usage** page itself uses (`/api/organizations` → `/api/organizations/{id}/usage`). You paste your `sessionKey` once; it's stored in the **macOS Keychain**, never in a plain file. Every request is a read-only `GET` — it can't touch your account or spend quota.

**It's unofficial.** If Anthropic changes the endpoint, the widget keeps running but shows a small `⚠` — see [*"If it stops working"*](#if-it-stops-working) below.

## Install

Requires Xcode Command Line Tools (`xcode-select --install`) — that's it, no Homebrew, no Python.

```bash
git clone https://github.com/currylaksa/claude-usage-bar-for-mac.git
cd claude-usage-bar-for-mac
chmod +x install.sh
./install.sh
```

This compiles the native Swift binary into `~/Applications/Claude Usage Bar.app` and registers a login agent so it starts automatically every time you log in. Look for `• set key` in your menu bar when it's done, then paste your session key (steps below).

## Launching it again (after Quit)

- **GUI:** ⌘Space → type "Claude Usage Bar" → Enter. Also sits in `~/Applications` for double-clicking. (Safe to launch while it's already running — it won't spawn a duplicate icon.)
- **CLI:**
  ```bash
  launchctl kickstart gui/$(id -u)/com.wilderfarer.claude-usage-bar
  ```

It auto-starts at every login regardless of whether you quit it last time.

## Install (manual, no installer script)

```bash
swiftc -O -parse-as-library -o claude-usage-bar ClaudeUsageBar.swift
./claude-usage-bar
```

For login-start, edit `com.wilderfarer.claude-usage-bar.plist` (replace the `__PLACEHOLDER__` path), drop it in `~/Library/LaunchAgents/`, and `launchctl load -w` it.

## Getting your sessionKey

1. Open <https://claude.ai> and make sure you're logged in.
2. Press **F12** → **Application** tab → **Cookies** → `https://claude.ai`.
3. Find the cookie named **`sessionKey`** (value starts with `sk-ant-sid01-…`).
4. Copy the value, click the widget → **Set session key…**, paste, **Save**.

You'll re-do this **roughly once a month**. The `sessionKey` lives about 30 days and gets extended by normal browser use; it only dies early if you log out of claude.ai or clear cookies. When that happens the widget shows `⚠ key` — just re-paste.

Your key never leaves your machine except in requests to `claude.ai` itself — this project has no server, no telemetry, no analytics.

## If it stops working

- **`⚠ key`** → your session key expired. Re-paste it (steps above).
- **`⚠` after the %** → the fetch failed or the endpoint moved; the number shown is the last good one. If it persists, the internal API likely changed.
- **Fixing a changed endpoint:** open `ClaudeUsageBar.swift` and find the `CLAUDE API` block near the top. The URLs and field names (`limits` array with `kind: "session"`, or the legacy `five_hour` bucket, `percent`, `resets_at`) are all there in one place. Re-capture the current shape via claude.ai → F12 → **Network** → visit `claude.ai/settings/usage` → the request ending in `/usage`, update those few lines, and re-run `./install.sh`. PRs for endpoint fixes welcome — see below.

## Notes

- Polls every 5 minutes; the countdown repaints every 30 s (and instantly when you open the menu — the display is minute-granular anyway).
- Requires macOS 13+ to run; Xcode Command Line Tools to build.
- Scope is deliberately **Claude only** — it's the one assistant that exposes real server-side usage numbers. (ChatGPT/Gemini only expose local *estimates*, so they were left out on purpose.)
- Uninstall:
  ```bash
  launchctl unload ~/Library/LaunchAgents/com.wilderfarer.claude-usage-bar.plist
  rm -rf ~/Applications/"Claude Usage Bar.app" ~/Library/LaunchAgents/com.wilderfarer.claude-usage-bar.plist
  ```

## Contributing

It's ~350 lines of Swift in one file, no build system beyond `swiftc`. Bug fixes (especially "the endpoint moved" fixes) and small feature PRs are welcome — keep it dependency-free and keep the resource footprint honest.

## License

[MIT](LICENSE) — do whatever you want with it.
