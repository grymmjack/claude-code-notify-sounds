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

[▶ Watch the demo](docs/claudecraft.mp4) — a Claude Code session narrated entirely in grumpy RTS units.

<video src="https://raw.githubusercontent.com/grymmjack/claude-code-notify-sounds/refs/heads/master/docs/claudecraft.mp4" controls width="360"></video>

> The inline `<video>` plays once the repo is pushed. If your browser or GitHub
> doesn't render it, use the [▶ Watch the demo](docs/claudecraft.mp4) link above,
> or drag `docs/claudecraft.mp4` into the README on github.com to get a
> `user-attachments` URL.

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
- A **desktop-notification** command: `notify-send` (Linux, from `libnotify-bin`).
  macOS falls back to `osascript`.
- A **sound player** — the first of these that's installed is used:
  `pw-play` (PipeWire) · `paplay` (PulseAudio) · `ffplay` · `aplay` · `afplay` (macOS).
- Built and tested on KDE Plasma / Wayland + PipeWire; works on most Linux desktops.

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
players — use `.wav`/`.ogg`.

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
shows a `notify-send` toast (with the daemon's own sound *suppressed* to avoid a
double chime), and plays the file **detached** so the hook returns instantly.
That's the whole trick.

## License

[MIT](LICENSE) — code only. Your sounds are your own.
