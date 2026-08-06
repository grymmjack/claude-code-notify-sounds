# Claude Code Notify Sounds 🔔🎮

Give [Claude Code](https://claude.com/claude-code) a voice. This is a tiny,
dependency-light hook that fires a **desktop notification + a sound** at key
moments in a session — when Claude needs you, when it finishes, when something
errors, when you deny a tool, and when a session starts.

Each event plays from its own **pool** of sounds, cycled **round-robin**, so you
can load three different "work complete" barks and hear them in rotation instead
of the same clip every single time.

> **Bring your own sounds.** This ships silent — drop `.wav`/`.ogg` files into the
> event folders and you're off. (It was built around classic RTS unit voices,
> which are copyrighted game rips and therefore *not* included — see [Sounds](#sounds).)

## Demo

A Claude Code session narrated entirely in grumpy RTS units. **Click to play** (GitHub opens its built-in video viewer):

https://github.com/user-attachments/assets/0662c765-f5f0-49a0-96b3-2c3026041286

## What it does

| Claude Code event | Plays from | Fires when… |
|---|---|---|
| `Notification` | `sounds/needs/` | Claude is blocked on you — a permission prompt, or the input sat idle |
| `Stop` | `sounds/ready/` | A turn finished cleanly — ready for your next message |
| `StopFailure` | `sounds/fail/` | A turn ended in an error |
| `PermissionDenied` | `sounds/denied/` | You denied a tool request |
| `SessionStart` | `sounds/start/` | A new session began |

The `Stop` + `StopFailure` pair is the sleeper feature: a *success* sound vs. an
*error* sound means your ears alone tell you how a turn ended while you're off in
another window.

## Requirements

- **Claude Code** (the CLI).
- **`jq`** — reads the event payload.
- **`bash`** — on Windows that means git-bash / MSYS2, which Claude Code uses to
  run hooks anyway.

### Platform support

`notify.sh` detects the OS from `uname -s` and prefers each platform's **native**
backend, falling back to the generic chain if it isn't there. Nothing to
configure — the same script works everywhere.

| | Notification | Sound | Click focuses the session's app |
|---|---|---|---|
| **Linux** | `notify-send` (from `libnotify-bin`) | `pw-play` (PipeWire) → `paplay` (PulseAudio) → `ffplay` → `aplay` | with `--action` support + `wmctrl`/`xdotool`/`kdotool` |
| **macOS** | `terminal-notifier` if installed, else `osascript` | `afplay` | with `terminal-notifier` |
| **Windows** | [BurntToast](https://github.com/Windos/BurntToast) if installed, else a tray balloon tip | `ffplay` if installed, else `Media.SoundPlayer` (**`.wav` only**) | balloon-tip path only |

Every backend is probed with `command -v` before use, so a missing tool means
*silence*, never an error. Built and tested on KDE Plasma / Wayland + PipeWire
and on macOS; the Windows path runs under git-bash.

Platform notes:

- **macOS** — the first toast needs your terminal app granted permission in
  **System Settings → Notifications**, or it silently shows nothing.
- **macOS: clicking the notification.** With plain `osascript`, macOS attributes
  the notification to **Script Editor** — so clicking it opens Script Editor,
  which is useless. `osascript` cannot set a click target (`display notification`
  comes from StandardAdditions, which loads into osascript's own process, and
  `tell application "X" to display notification` needs X to be
  AppleScript-scriptable — VS Code and the Claude desktop app both ship no
  `.sdef`). Fix it with:
  ```bash
  brew install terminal-notifier
  ```
  Then clicking a notification focuses **the app the session is running in** —
  Claude desktop, VS Code, iTerm, whatever launched it — detected from
  `__CFBundleIdentifier`, falling back to walking the process ancestry for the
  enclosing `.app`. Pin it to one app with
  `CLAUDE_NOTIFY_ACTIVATE=com.microsoft.VSCode`.

  This uses terminal-notifier's `-activate`, not `-sender`. `-sender` would also
  borrow the app's icon and name, but it **hangs forever for some bundle ids**
  (reproducible with the Claude desktop app, even after granting notification
  permission) — not worth a leaked process on every turn for a nicer icon. The
  cost of `-activate` is cosmetic: the toast shows terminal-notifier's icon.

- **Linux: clicking the notification.** If your `notify-send` supports
  `--action` (libnotify 0.7.7+), the hook registers the freedesktop spec's
  `default` action — the one invoked by clicking the notification body — and
  raises the session's window when it fires. You also need a window tool:
  ```bash
  sudo apt install wmctrl xdotool     # X11 / XWayland
  ```
  Matching is by **PID** first (`wmctrl -lp`, then `xdotool search --pid`), which
  is exact, falling back to window class. On **KDE Plasma under Wayland** X11
  tools cannot see native Wayland windows at all — install
  [`kdotool`](https://github.com/jinliu/kdotool), which drives KWin's scripting
  API, and the hook will use it automatically.

  Note that `notify-send --action` **blocks** until the notification is clicked or
  expires, so the call is detached and bounded by
  `CLAUDE_NOTIFY_CLICK_TIMEOUT_MS` (default 12000). Without `--action` support or
  a window tool, you get exactly the previous behavior — a plain notification.

- **Windows: clicking the notification.** The tray-balloon path attaches a
  `BalloonTipClicked` handler that calls `WScript.Shell`'s `AppActivate`. A
  **BurntToast** toast routes its click to the AppId that posted it, which would
  require registering a shortcut with an AppUserModelID — out of scope — so
  BurntToast toasts stay cosmetic on click. Set
  `CLAUDE_NOTIFY_NO_BURNTTOAST=1` to force the balloon path and get
  click-to-focus. Detection of the host app also depends on MSYS `ps` supporting
  `-o comm=`; where it doesn't, click-to-focus is skipped harmlessly.

- **Opting out:** `CLAUDE_NOTIFY_NO_CLICK=1` disables all click handling on every
  platform and restores the plain-notification behavior.
- **Windows** — `Media.SoundPlayer` plays `.wav` only and has no volume control,
  so `CLAUDE_NOTIFY_VOLUME` is ignored on that path. Install `ffmpeg` (for
  `ffplay`) if you want `.ogg`/`.flac` and working volume. `Install-Module
  BurntToast` gets you real toasts instead of the balloon-tip fallback.

## Install

1. Clone somewhere permanent and make the scripts executable:
   ```bash
   git clone https://github.com/YOU/claude-code-notify-sounds ~/claude-code-notify-sounds
   cd ~/claude-code-notify-sounds
   chmod +x notify.sh install.sh
   ```
2. **Add sounds** — drop files into the event folders (any count per folder; they cycle):
   ```
   sounds/needs/   sounds/ready/   sounds/fail/   sounds/denied/   sounds/start/
   ```
3. **Wire up the hooks.** Generate the settings block with the correct absolute path:
   ```bash
   ./install.sh
   ```
   Merge its output into `~/.claude/settings.json` under `"hooks"`.
   **Merge — don't replace** any hooks you already have; if you already have a
   `SessionStart` hook, add this one *alongside* it in the same `hooks` array.
4. **Reload:** open Claude Code's `/hooks` menu once, or restart Claude Code.

### Quick test (no waiting for real events)

```bash
echo '{"cwd":"'"$PWD"'"}' | ./notify.sh stop        # play a "ready" sound + toast
NOTIFY_DEBUG=1 echo '{}' | ./notify.sh stopfail     # prints which clip it picked
```

## Customize

- **Volume:** `VOL` at the top of `notify.sh` (`0.0`–`1.0`), or set `CLAUDE_NOTIFY_VOLUME`.
- **Sound location:** set `CLAUDE_NOTIFY_SOUNDS` to point the folders elsewhere.
- **Add / remove events:** each hook is one line in your settings — delete the ones
  you don't want.
- **Round-robin state** lives in `sounds/.rr/` (one tiny counter per event). Delete it to reset.

Events deliberately left out because they fire *constantly* and would drive you
mad: `PreToolUse`, `PostToolUse`, `UserPromptSubmit`. Add them at your own peril. 🙂

## Troubleshooting

**No sound, and your notifications say they come from some *other* daemon
(e.g. Xfce) instead of your desktop's own:**
Only one process can own the `org.freedesktop.Notifications` D-Bus name; if a
stray daemon grabbed it, your desktop's notifier (with its sound settings) never
runs. Stop the stray from auto-starting. Example for a KDE box where
`xfce4-notifyd` snuck in:
```bash
systemctl --user mask xfce4-notifyd.service
systemctl --user restart plasma-plasmashell.service   # let Plasma reclaim the name
```
This project sidesteps the issue by playing sound **itself**, independent of the
notification daemon — but fixing ownership restores your desktop's native toast styling.

**Toasts show but no sound:** confirm a player exists
(`command -v pw-play paplay ffplay aplay afplay`) and that the file plays directly
(`pw-play sounds/ready/yourfile.wav`). `.mp3` isn't supported by the libsndfile
players — use `.wav`/`.ogg`. On Windows without `ffplay`, only `.wav` will play.

**Nothing at all happens:** run it by hand with the debug flag — it prints the
detected platform and the clip it picked, then exits 0 regardless:
```bash
echo '{"cwd":"'"$PWD"'"}' | NOTIFY_DEBUG=1 ./notify.sh stop
# notify.sh os=mac     stop      -> Owrkdone.wav
```
`os=unknown` means `uname -s` wasn't recognized and only the generic chain will be
tried. `-> none` means the folder for that event has no playable files in it.

**macOS shows no toast:** grant your terminal app (Terminal, iTerm, Ghostty, …)
permission under **System Settings → Notifications**. `osascript` fails silently
without it.

**Hook doesn't fire:** newly-added hook *events* sometimes need a config reload —
open `/hooks` once or restart. Validate your settings
(`jq . ~/.claude/settings.json`); one JSON syntax error silently disables every
setting in that file.

## Sounds

**None are bundled** — the repo ships silent so it stays legally clean and works
with any audio you like:

- **Free / CC0:** your system's freedesktop theme
  (`/usr/share/sounds/freedesktop/stereo/*.oga`),
  [Kenney](https://kenney.nl/assets?q=audio) UI packs, [freesound.org](https://freesound.org).
- **Game voices** make it delightful but are **copyrighted** — use them only from a
  copy you legally own, for personal use, and don't redistribute them.

### Recreate the Warcraft II set (what the demo uses)

The demo uses unit-voice clips from **Warcraft II** (© Blizzard Entertainment).
They are **not** in this repo — download them yourself and drop them into the
folders. Source used:
<https://sounds.spriters-resource.com/ms_dos/warcraftii/asset/393991/>

| Folder | Files |
|---|---|
| `sounds/needs/`  | `Oready.wav` · `Psready.wav` · `Pnready.wav` |
| `sounds/ready/`  | `Owrkdone.wav` · `Pswrkdon.wav` · `Hwhat6.wav` |
| `sounds/fail/`   | `Gopissd2.wav` · `Dwhat2.wav` · `Opissed2.wav` |
| `sounds/denied/` | `Ompissd3.wav` · `Pspissd6.wav` · `Ogpissd1.wav` |
| `sounds/start/`  | `Ogready.wav` · `Pkready.wav` · `Wzready.wav` |

> These are Blizzard's assets; the table is just filenames. Download for personal
> use only — don't commit them to a public fork.

## How it works

`notify.sh <event>` reads the hook's JSON payload on stdin, maps the event to a
`sounds/<folder>`, picks the next file round-robin (a counter in `sounds/.rr/`),
shows a toast via the platform's native notifier (on Linux, `notify-send` with the
daemon's own sound *suppressed* to avoid a double chime), and plays the file
**detached** so the hook returns instantly. That's the whole trick.

It always exits **0**. That matters: `notify.sh` runs on the `Stop` event, where a
nonzero status is reported as a hook failure — and where an exit status of `2`
specifically means *"don't end the turn."* So a missing player, a silent folder, or
an unrecognized OS can never turn a cosmetic notification into a broken session.

## License

[MIT](LICENSE) — code only. Your sounds are your own.
