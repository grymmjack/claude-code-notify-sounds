# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single-script Claude Code hook (`notify.sh`) that fires a desktop notification + sound at
lifecycle events. It ships **silent** — users drop their own `.wav`/`.ogg` files into
`sounds/<event>/` folders. No build step, no dependencies to install beyond `jq` and `bash`.

## Testing changes

There is no test suite. Exercise `notify.sh` by feeding it a hook payload on stdin and an
event name as `$1`. `NOTIFY_DEBUG=1` prints the detected OS, the clip picked, and (per
platform) the click-to-focus diagnostics to stderr, then exits 0 regardless:

```bash
echo '{"cwd":"'"$PWD"'"}' | NOTIFY_DEBUG=1 ./notify.sh stop        # ready sound + toast
echo '{}' | NOTIFY_DEBUG=1 ./notify.sh stopfail                    # fail path
echo '{"tool_name":"Bash"}' | NOTIFY_DEBUG=1 ./notify.sh denied    # denied, uses tool_name
```

Events map to folders: `notification→needs`, `stop→ready`, `stopfail→fail`,
`denied→denied`, `start→start`. Any unrecognized event falls through to `needs`.

`install.sh` just `sed`-substitutes this repo's absolute path into `hooks.settings.json`
and prints the result for the user to merge into `~/.claude/settings.json`. Nothing writes
their settings automatically.

## Invariants — do not break these

- **`notify.sh` must always `exit 0`** (last line). It runs on the `Stop` hook, where a
  nonzero status is a hook failure and exit `2` specifically means "don't end the turn." A
  missing player, an empty sound folder (the state of every fresh clone), or an unknown OS
  must degrade to silence, never a nonzero exit. Any new early-return path must preserve this.
- **Probe every external tool with `command -v` before using it**, and fall back. A missing
  backend means silence, not an error. This is why the script works unconfigured on any OS.
- **Play sounds and post notifications detached** via `spawn()` (setsid, or a backgrounded
  subshell) so the hook returns instantly — hooks block the session while running.
- **Native backend preference is deliberate.** `play_detached` explicitly picks the
  platform's native player (afplay on mac, ffplay/SoundPlayer on Windows) *before* the
  generic chain, so a Mac with ffmpeg installed doesn't pick ffplay over afplay by chain
  order alone. Don't collapse this back into one flat chain.
- **`$ROLE` uses a colon-less default on purpose:** `ROLE="${CLAUDE_NOTIFY_ROLE-Notification}"`.
  This lets an *explicitly empty* `CLAUDE_NOTIFY_ROLE=` opt out (generic channel) while an
  *unset* var gets the `Notification` default. Do **not** "fix" it to `:-`, which treats
  empty as unset and breaks the opt-out. At the call sites the tag is emitted with
  `${ROLE:+…}` so an empty `$ROLE` adds no flag at all.

## Architecture notes

- **OS detection** is from `uname -s` into `$OS` (mac/linux/windows/unknown); every
  platform-specific branch keys off it, and `unknown` uses only the generic chain.
- **Media role (Linux only)** — `pw-play`/`paplay` tag the stream with the `Notification`
  media role (`$ROLE`, from `CLAUDE_NOTIFY_ROLE`) so the desktop routes it to its dedicated
  Notification Sounds volume slider; final level ≈ `CLAUDE_NOTIFY_VOLUME` × that slider.
  PulseAudio's role is named `event` (which `pipewire-pulse` maps back to `Notification`).
  `ffplay`/`aplay` have no role concept and always play on the generic channel — a change
  there won't reach the slider. Verify the tag with `pactl list sink-inputs | grep media.role`.
- **Round-robin** state is one counter file per event under `sounds/.rr/`. The pool is
  `find`-ed and `LC_ALL=C sort`-ed so the rotation order is stable across machines; the
  counter is sanitized against corruption before use.
- **Click-to-focus** is the most intricate part, and each platform needs its own route
  because only macOS has an `-activate` flag:
  - **macOS** — `terminal-notifier -activate <bundle-id>` (NOT `-sender`, which hangs
    forever for some bundle ids). Target resolved via `mac_activate_target`:
    `$CLAUDE_NOTIFY_ACTIVATE` → `$__CFBundleIdentifier` → climbing process ancestry for the
    outermost `.app`. Plain `osascript` fallback can't set a click target (a click opens
    Script Editor) — that's a known limitation, not a bug to "fix" in osascript.
  - **Linux** — `notify-send --action=default=Focus` **blocks** until clicked/expired, so
    it's spawned and bounded by `$CLAUDE_NOTIFY_CLICK_TIMEOUT_MS`. On click it re-invokes
    `notify.sh --focus <pids> <class>`, which raises the window via wmctrl→xdotool (X11) or
    kdotool (KDE Wayland, where X11 tools can't see native windows). Ancestor PIDs and
    window class are resolved *before* detaching, since the watcher's own ancestry differs
    once reparented.
  - **Windows** — tray-balloon path only (`BalloonTipClicked` → `AppActivate`); BurntToast
    toasts stay cosmetic on click by design.
- The **`--focus` internal entry point** is checked at the top of the script, before the
  main path reads stdin. It's not for interactive use.
- **`CLAUDE_NOTIFY_NO_CLICK=1`** disables all click handling everywhere and restores plain
  notifications — keep this escape hatch working across all three platforms.

## Documentation

`README.md`, `sounds/README.md`, and the header comments in `notify.sh` are extensive and
kept in sync with behavior. If you change platform behavior, env vars, event mappings, or
the click logic, update the relevant docs in the same change — the README's platform table
and the in-script comments are the project's real spec.
