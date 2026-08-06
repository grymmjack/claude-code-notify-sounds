#!/usr/bin/env bash
# claude-code-notify-sounds — desktop notifications + sound cues for Claude Code.
#
# Fires a desktop notification and a sound when Claude Code hits a lifecycle
# event. Sounds live in per-event folders and are cycled round-robin, so each
# event can hold a POOL of clips that rotate (no repeats until the pool is spent).
#
# Wired via ~/.claude/settings.json hooks (see README). Called as:
#   notify.sh <event>     event = notification | stop | stopfail | denied | start
# The hook's JSON payload arrives on STDIN.
#
#   event         Claude Code hook   folder          meaning
#   notification  Notification       sounds/needs    blocked on you (permission / idle)
#   stop          Stop               sounds/ready    a turn finished cleanly
#   stopfail      StopFailure        sounds/fail     a turn ended in an error
#   denied        PermissionDenied   sounds/denied   you denied a permission request
#   start         SessionStart       sounds/start    a new session started
#
# Drop .wav/.ogg/.oga/.flac into the matching folder. Empty folder = silent.
# No script editing required to customize sounds.
#
# PLATFORM SUPPORT — detected from `uname -s`, native backend preferred:
#   Linux    notify-send                    + pw-play / paplay / ffplay / aplay
#   macOS    osascript                      + afplay
#   Windows  BurntToast or tray balloon tip + ffplay, or Media.SoundPlayer (.wav)
#            (run under git-bash / MSYS2 — Claude Code invokes this with bash)
# Every backend is probed with `command -v` first and each platform falls back to
# the generic chain, so a missing tool degrades to silence rather than an error.

set -u

# ---- config -----------------------------------------------------------------
SELF="$(readlink -f "$0" 2>/dev/null || echo "$0")"
SELF_DIR="$(cd "$(dirname "$SELF")" && pwd)"
SNDDIR="${CLAUDE_NOTIFY_SOUNDS:-$SELF_DIR/sounds}"   # override with an env var
VOL="${CLAUDE_NOTIFY_VOLUME:-0.35}"                  # 0.0 (silent) .. 1.0 (full)
APPNAME="Claude Code"
# How long the Linux click-to-focus watcher waits for a click before giving up.
# It exists only on that path, where notify-send blocks until the notification is
# clicked or expires; this bounds the detached process's lifetime.
CLICK_TIMEOUT_MS="${CLAUDE_NOTIFY_CLICK_TIMEOUT_MS:-12000}"

case "$(uname -s 2>/dev/null)" in
  Darwin)                OS=mac ;;
  Linux)                 OS=linux ;;
  MINGW*|MSYS*|CYGWIN*)  OS=windows ;;
  *)                     OS=unknown ;;
esac
# -----------------------------------------------------------------------------

spawn() {   # run a command detached so it outlives this short-lived hook
  if command -v setsid >/dev/null 2>&1; then setsid -f "$@" >/dev/null 2>&1 && return 0; fi
  ( "$@" >/dev/null 2>&1 & )
}

# ---- escaping / conversion helpers ------------------------------------------
# AppleScript double-quoted string: escape backslash first, then double quote.
as_escape() { local s="$1"; s="${s//\\/\\\\}"; printf '%s' "${s//\"/\\\"}"; }
# PowerShell single-quoted string: a literal single quote is doubled.
ps_escape() { printf '%s' "${1//\'/\'\'}"; }
# git-bash/MSYS path -> native Windows path, for PowerShell consumption.
win_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1" 2>/dev/null; else printf '%s' "$1"; fi; }
# 0.0..1.0 -> 0..65536 (paplay) and -> 0..100 (ffplay), both clamped.
vol_pa()  { awk -v v="$1" 'BEGIN{if(v<0)v=0; if(v>1)v=1; printf "%d", v*65536}' 2>/dev/null || printf '22937'; }
vol_pct() { awk -v v="$1" 'BEGIN{if(v<0)v=0; if(v>1)v=1; printf "%d", v*100}'   2>/dev/null || printf '35'; }

play_detached() {   # play $1 at volume $2 via the best available player
  local f="$1" vol="$2"
  [ -r "$f" ] || return 0

  # Prefer each platform's NATIVE player. Without this, a Mac with ffmpeg
  # installed would pick ffplay over afplay purely by chain order.
  case "$OS" in
    mac)
      if command -v afplay >/dev/null 2>&1; then spawn afplay -v "$vol" "$f"; return 0; fi
      ;;
    windows)
      # ffplay handles every format this project supports; Media.SoundPlayer is
      # .wav-only and has no volume control, so it is the second choice.
      if command -v ffplay >/dev/null 2>&1; then
        spawn ffplay -nodisp -autoexit -loglevel quiet -volume "$(vol_pct "$vol")" "$f"; return 0
      fi
      if command -v powershell.exe >/dev/null 2>&1; then
        case "$f" in
          *.wav|*.WAV)
            spawn powershell.exe -NoProfile -NonInteractive -Command \
              "(New-Object Media.SoundPlayer '$(ps_escape "$(win_path "$f")")').PlaySync()"
            return 0 ;;
        esac
      fi
      ;;
  esac

  # Generic chain — first class on Linux, and the fallback everywhere else.
  if   command -v pw-play >/dev/null 2>&1; then spawn pw-play --volume "$vol" "$f"
  elif command -v paplay  >/dev/null 2>&1; then spawn paplay --volume "$(vol_pa "$vol")" "$f"
  elif command -v ffplay  >/dev/null 2>&1; then spawn ffplay -nodisp -autoexit -loglevel quiet -volume "$(vol_pct "$vol")" "$f"
  elif command -v afplay  >/dev/null 2>&1; then spawn afplay -v "$vol" "$f"
  elif command -v aplay   >/dev/null 2>&1; then spawn aplay -q "$f"          # no volume control
  fi
  return 0
}

# Which app should clicking a macOS notification bring to the front?
#
# THE PROBLEM: `osascript -e 'display notification'` is posted BY osascript, so
# macOS attributes it to Script Editor — and clicking the notification opens
# Script Editor rather than the app you were working in. osascript cannot set a
# click target: `display notification` comes from StandardAdditions, which loads
# into osascript's own process, and `tell application "X" to display
# notification` does not help because X must be AppleScript-scriptable (neither
# VS Code nor the Claude desktop app ships a .sdef). terminal-notifier's
# -activate flag is the only reliable fix. Install it with:
#   brew install terminal-notifier
#
# Resolution order: explicit override -> the bundle id the host app exports in
# __CFBundleIdentifier -> climb the process ancestry for the enclosing .app.
mac_activate_target() {
  if [ -n "${CLAUDE_NOTIFY_ACTIVATE:-}" ]; then printf '%s' "$CLAUDE_NOTIFY_ACTIVATE"; return 0; fi
  if [ -n "${__CFBundleIdentifier:-}" ]; then printf '%s' "$__CFBundleIdentifier"; return 0; fi

  # Keep the LAST (outermost) .app found while climbing: inner matches are helper
  # bundles, the outermost one is the real GUI host.
  local pid=$$ i=0 ppid comm app bid found=""
  while [ "$i" -lt 12 ]; do
    ppid=""; comm=""
    read -r ppid comm <<< "$(ps -o ppid=,comm= -p "$pid" 2>/dev/null | sed 's/^ *//')"
    [ -n "$comm" ] || break
    case "$comm" in
      *.app/Contents/*)
        app="${comm%%.app/Contents/*}.app"
        bid="$(defaults read "$app/Contents/Info" CFBundleIdentifier 2>/dev/null)"
        [ -n "$bid" ] && found="$bid"
        ;;
    esac
    [ -n "$ppid" ] || break
    [ "$ppid" = "1" ] && break
    pid="$ppid"; i=$((i+1))
  done
  [ -n "$found" ] && { printf '%s' "$found"; return 0; }
  return 1
}

# ---- click-to-focus: Linux and Windows --------------------------------------
#
# Same goal as mac_activate_target above — clicking a notification should raise
# the app the session came from — but neither platform has an -activate flag, so
# each needs its own route:
#
#   Linux    notify-send registers the freedesktop spec's "default" action (the
#            key invoked when the user clicks the notification body) and BLOCKS
#            until it fires or the notification closes. So the call is detached
#            and time-bounded, and on click it re-invokes this script with
#            --focus to raise the window.
#   Windows  the tray-balloon path attaches a BalloonTipClicked handler that
#            calls WScript.Shell AppActivate. Self-contained, no re-invoke.
#
# Both degrade to exactly the previous behavior (a plain notification, no click
# handling) whenever the required tooling is missing.

# Ancestor PIDs, nearest first. The GUI app owning the session is up this chain,
# and matching a window to one of these PIDs is the most precise way to find it.
ancestor_pids() {
  local pid=$$ i=0 ppid out=""
  while [ "$i" -lt 14 ]; do
    out="$out $pid"
    ppid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
    case "${ppid:-}" in ''|0|1) break ;; esac
    pid="$ppid"; i=$((i+1))
  done
  printf '%s' "${out# }"
}

# Best guess at the GUI host's window class / process name, for compositors that
# match by class rather than PID. Walks up past shells and interpreters.
host_app_name() {
  [ -n "${CLAUDE_NOTIFY_ACTIVATE:-}" ] && { printf '%s' "$CLAUDE_NOTIFY_ACTIVATE"; return 0; }
  local pid comm
  for pid in $(ancestor_pids); do
    comm="$(ps -o comm= -p "$pid" 2>/dev/null | sed 's|.*/||')"
    case "$comm" in
      ''|ps|sed|awk|bash|sh|zsh|fish|dash|ksh|tcsh|login|su|sudo|env|node|claude|systemd|init) continue ;;
      tmux*|screen) continue ;;
      *) printf '%s' "$comm"; return 0 ;;
    esac
  done
  return 1
}

linux_focus() {   # $1 candidate pids (space separated)   $2 window class or ""
  local pids="${1:-}" class="${2:-}" wid p
  # wmctrl matching by PID is the most precise. X11 / XWayland only.
  if command -v wmctrl >/dev/null 2>&1; then
    wid="$(wmctrl -lp 2>/dev/null | awk -v p=" $pids " '{ if (index(p, " "$3" ")) { print $1; exit } }')"
    [ -n "$wid" ] && wmctrl -i -a "$wid" 2>/dev/null && return 0
    [ -n "$class" ] && wmctrl -x -a "$class" 2>/dev/null && return 0
  fi
  if command -v xdotool >/dev/null 2>&1; then
    for p in $pids; do
      wid="$(xdotool search --pid "$p" 2>/dev/null | head -1)"
      [ -n "$wid" ] && xdotool windowactivate "$wid" 2>/dev/null && return 0
    done
    [ -n "$class" ] && xdotool search --class "$class" windowactivate 2>/dev/null && return 0
  fi
  # KDE Plasma on Wayland: X11 tools cannot see native Wayland windows at all,
  # so drive KWin's scripting API through kdotool instead.
  if [ -n "$class" ] && command -v kdotool >/dev/null 2>&1; then
    kdotool search --class "$class" windowactivate 2>/dev/null && return 0
  fi
  return 1
}

windows_focus() {   # $1 window-title substring or process name
  local t="${1:-}"
  [ -n "$t" ] || return 1
  command -v powershell.exe >/dev/null 2>&1 || return 1
  powershell.exe -NoProfile -NonInteractive -Command \
    "\$ErrorActionPreference='SilentlyContinue'; (New-Object -ComObject WScript.Shell).AppActivate('$(ps_escape "$t")')" \
    >/dev/null 2>&1
}

# INTERNAL entry point, used by the detached Linux click-watcher to raise the
# window after a click. Must run before the main path, which blocks reading the
# hook payload from stdin. Not intended for interactive use.
if [ "${1:-}" = "--focus" ]; then
  case "$OS" in
    linux)   linux_focus   "${2:-}" "${3:-}" ;;
    windows) windows_focus "${3:-}" ;;
    mac)     [ -n "${3:-}" ] && open -b "${3:-}" >/dev/null 2>&1 ;;
  esac
  exit 0
fi

show_toast() {   # $1 title  $2 body  $3 icon  $4 urgency  $5 dedup-tag
  case "$OS" in
    mac)
      # Preferred: terminal-notifier, so a click focuses the app the session
      # came from instead of Script Editor.
      #
      # -activate, NOT -sender. -sender would also show the app's own icon and
      # name, but it HANGS FOREVER for some bundle ids (reproducible for the
      # Claude desktop app, even with notification permission granted). This
      # runs on every turn, so a leaked process per notification is not worth a
      # prettier icon. spawn() detaches it anyway, belt and braces.
      if command -v terminal-notifier >/dev/null 2>&1; then
        local target; target="$(mac_activate_target || true)"
        if [ -n "$target" ]; then
          spawn terminal-notifier -title "$1" -message "$2" -group "$5" -activate "$target"
        else
          spawn terminal-notifier -title "$1" -message "$2" -group "$5"
        fi
        return 0
      fi
      if command -v osascript >/dev/null 2>&1; then
        # Fallback: works, but a click opens Script Editor (see above) and the
        # terminal app needs Notification permission granted in
        # System Settings > Notifications, or this silently shows nothing.
        osascript -e "display notification \"$(as_escape "$2")\" with title \"$(as_escape "$1")\"" \
          >/dev/null 2>&1 || true
        return 0
      fi
      ;;
    windows)
      if command -v powershell.exe >/dev/null 2>&1; then
        local t b ps focus
        t="$(ps_escape "$1")"; b="$(ps_escape "$2")"
        focus="$(ps_escape "$(host_app_name || true)")"
        # BurntToast gives a real toast if installed; otherwise fall back to a
        # tray balloon tip, which needs its process alive for the duration —
        # hence spawn, so the hook itself returns immediately.
        #
        # CLICK-TO-FOCUS applies to the BALLOON path only: BalloonTipClicked is a
        # real event we can hook, and AppActivate raises the window by title or
        # process name. A BurntToast toast routes its click to the AppId that
        # posted it, which would mean registering a shortcut with an
        # AppUserModelID — out of scope here, so BurntToast toasts are still
        # cosmetic-only on click. Set CLAUDE_NOTIFY_NO_BURNTTOAST=1 to force the
        # balloon path and get click-to-focus.
        ps="\$ErrorActionPreference='SilentlyContinue';"
        if [ -n "${CLAUDE_NOTIFY_NO_BURNTTOAST:-}" ]; then
          ps="$ps if (\$false) {"
        else
          ps="$ps if (Get-Module -ListAvailable -Name BurntToast) {"
        fi
        ps="$ps Import-Module BurntToast; New-BurntToastNotification -Text '$t','$b'"
        ps="$ps } else {"
        ps="$ps Add-Type -AssemblyName System.Windows.Forms;"
        ps="$ps Add-Type -AssemblyName System.Drawing;"
        ps="$ps \$ni=New-Object System.Windows.Forms.NotifyIcon;"
        ps="$ps \$ni.Icon=[System.Drawing.SystemIcons]::Information;"
        ps="$ps \$ni.Visible=\$true;"
        if [ -n "$focus" ] && [ -z "${CLAUDE_NOTIFY_NO_CLICK:-}" ]; then
          ps="$ps \$ni.add_BalloonTipClicked({"
          ps="$ps (New-Object -ComObject WScript.Shell).AppActivate('$focus') });"
        fi
        ps="$ps \$ni.ShowBalloonTip(5000,'$t','$b','Info');"
        ps="$ps Start-Sleep -Seconds 5; \$ni.Dispose() }"
        spawn powershell.exe -NoProfile -NonInteractive -Command "$ps"
        return 0
      fi
      ;;
  esac

  # Generic: notify-send (Linux), then osascript as a last resort.
  if command -v notify-send >/dev/null 2>&1; then
    # Click-to-focus, when this notify-send understands --action. Registering the
    # spec's "default" action makes a body click invokable, but notify-send then
    # BLOCKS until the action fires or the notification expires — so the call is
    # detached via spawn() and bounded by -t. The ancestor PIDs and window class
    # are resolved HERE, before detaching, because the watcher's own ancestry is
    # different once it is reparented.
    if [ "$OS" = linux ] && [ -z "${CLAUDE_NOTIFY_NO_CLICK:-}" ] \
       && notify-send --help 2>&1 | grep -qi -- '--action'; then
      local pids class
      pids="$(ancestor_pids)"; class="$(host_app_name || true)"
      spawn bash -c '
        act="$(notify-send --app-name="$1" --urgency="$2" --icon="$3" -t "$4" \
                 -h "string:x-canonical-private-synchronous:$5" \
                 -h "string:suppress-sound:true" \
                 --action=default=Focus "$6" "$7" 2>/dev/null)"
        [ "$act" = "default" ] && exec "$8" --focus "$9" "${10}"
        exit 0
      ' _ "$APPNAME" "$4" "$3" "$CLICK_TIMEOUT_MS" "$5" "$1" "$2" "$SELF" "$pids" "$class"
      return 0
    fi
    notify-send --app-name="$APPNAME" --urgency="$4" --icon="$3" \
      -h "string:x-canonical-private-synchronous:$5" \
      -h "string:suppress-sound:true" \
      "$1" "$2" >/dev/null 2>&1 || true
  elif command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"$(as_escape "$2")\" with title \"$(as_escape "$1")\"" >/dev/null 2>&1 || true
  fi
  return 0
}

# ---- resolve event ----------------------------------------------------------
event="${1:-notification}"
payload="$(cat 2>/dev/null || true)"
json() { printf '%s' "$payload" | jq -r "$1 // empty" 2>/dev/null; }
msg="$(json '.message')"; cwd="$(json '.cwd')"; tool="$(json '.tool_name')"
proj="$(basename "${cwd:-$PWD}")"

case "$event" in
  stop)      folder=ready;  body="Ready for you — turn finished";      icon=dialog-information; urgency=normal   ;;
  stopfail)  folder=fail;   body="Turn ended with an error";           icon=dialog-error;       urgency=critical ;;
  denied)    folder=denied; body="Permission denied${tool:+ — $tool}"; icon=dialog-warning;     urgency=normal   ;;
  start)     folder=start;  body="Session started";                    icon=dialog-information; urgency=low      ;;
  *)         folder=needs;  body="${msg:-Waiting for your input}";     icon=dialog-question;    urgency=critical ;;
esac
title="$APPNAME · $proj"

# ---- round-robin pick from sounds/<folder> ----------------------------------
sound=""
if [ -d "$SNDDIR/$folder" ]; then
  pool=()
  while IFS= read -r f; do [ -n "$f" ] && pool+=("$f"); done < <(
    find "$SNDDIR/$folder" -maxdepth 1 -type f \
      \( -iname '*.wav' -o -iname '*.ogg' -o -iname '*.oga' -o -iname '*.flac' \) 2>/dev/null | LC_ALL=C sort
  )
  n="${#pool[@]}"
  if [ "$n" -gt 0 ]; then
    rr="$SNDDIR/.rr"; mkdir -p "$rr" 2>/dev/null
    sf="$rr/$folder"; idx=0
    [ -r "$sf" ] && idx="$(cat "$sf" 2>/dev/null)"
    case "$idx" in ''|*[!0-9]*) idx=0 ;; esac      # sanitize a corrupt/empty state
    pick=$(( idx % n ))
    printf '%s' "$(( (idx + 1) % n ))" > "$sf" 2>/dev/null   # advance & wrap
    sound="${pool[$pick]}"
  fi
fi

# NOTIFY_DEBUG=1 prints the platform + selection to stderr (handy for testing).
[ -n "${NOTIFY_DEBUG:-}" ] && printf 'notify.sh os=%-7s %-9s -> %s\n' \
  "$OS" "$event" "$(basename "${sound:-none}")" >&2
# On macOS also report which app a click will focus and how that was decided —
# otherwise it is invisible until you click one and land somewhere unexpected.
if [ -n "${NOTIFY_DEBUG:-}" ] && [ "$OS" = mac ]; then
  if   [ -n "${CLAUDE_NOTIFY_ACTIVATE:-}" ]; then dbg_src="CLAUDE_NOTIFY_ACTIVATE"
  elif [ -n "${__CFBundleIdentifier:-}" ];    then dbg_src="__CFBundleIdentifier"
  else dbg_src="process-ancestry"; fi
  printf 'notify.sh activate=%s (via %s) notifier=%s\n' \
    "$(mac_activate_target || echo '<none>')" "$dbg_src" \
    "$(command -v terminal-notifier >/dev/null 2>&1 && echo terminal-notifier || echo 'osascript (click opens Script Editor)')" >&2
elif [ -n "${NOTIFY_DEBUG:-}" ] && { [ "$OS" = linux ] || [ "$OS" = windows ]; }; then
  # Everything the click path depends on, in one line — otherwise diagnosing "the
  # click did nothing" means guessing which of four things was missing.
  dbg_tool="none"
  for t in wmctrl xdotool kdotool; do
    command -v "$t" >/dev/null 2>&1 && { dbg_tool="$t"; break; }
  done
  if [ "$OS" = linux ]; then
    notify-send --help 2>&1 | grep -qi -- '--action' && dbg_act="yes" || dbg_act="NO (plain notification)"
    printf 'notify.sh click: --action=%s wm-tool=%s class=%s pids=%s%s\n' \
      "$dbg_act" "$dbg_tool" "$(host_app_name || echo '<none>')" "$(ancestor_pids)" \
      "${CLAUDE_NOTIFY_NO_CLICK:+ [DISABLED via CLAUDE_NOTIFY_NO_CLICK]}" >&2
  else
    printf 'notify.sh click: focus-target=%s burnttoast=%s%s\n' \
      "$(host_app_name || echo '<none>')" \
      "$([ -n "${CLAUDE_NOTIFY_NO_BURNTTOAST:-}" ] && echo forced-off || echo auto)" \
      "${CLAUDE_NOTIFY_NO_CLICK:+ [DISABLED via CLAUDE_NOTIFY_NO_CLICK]}" >&2
  fi
fi

show_toast "$title" "$body" "$icon" "$urgency" "ccns-$proj"
[ -n "$sound" ] && play_detached "$sound" "$VOL"

# ALWAYS exit 0. This runs on the Stop hook, where a nonzero status is reported
# as a hook failure — and on Claude Code's Stop event an exit status of 2 means
# "do not end the turn". Without this line the script's status came from the
# `[ -n "$sound" ]` test above, so a silent (empty) sound folder — the state of
# every folder on a fresh clone — made every event exit 1.
exit 0
