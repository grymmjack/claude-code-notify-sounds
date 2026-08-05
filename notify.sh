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

show_toast() {   # $1 title  $2 body  $3 icon  $4 urgency  $5 dedup-tag
  case "$OS" in
    mac)
      if command -v osascript >/dev/null 2>&1; then
        # The terminal app needs Notification permission granted in
        # System Settings > Notifications, or this silently shows nothing.
        osascript -e "display notification \"$(as_escape "$2")\" with title \"$(as_escape "$1")\"" \
          >/dev/null 2>&1 || true
        return 0
      fi
      ;;
    windows)
      if command -v powershell.exe >/dev/null 2>&1; then
        local t b ps
        t="$(ps_escape "$1")"; b="$(ps_escape "$2")"
        # BurntToast gives a real toast if installed; otherwise fall back to a
        # tray balloon tip, which needs its process alive for the duration —
        # hence spawn, so the hook itself returns immediately.
        ps="\$ErrorActionPreference='SilentlyContinue';"
        ps="$ps if (Get-Module -ListAvailable -Name BurntToast) {"
        ps="$ps Import-Module BurntToast; New-BurntToastNotification -Text '$t','$b'"
        ps="$ps } else {"
        ps="$ps Add-Type -AssemblyName System.Windows.Forms;"
        ps="$ps Add-Type -AssemblyName System.Drawing;"
        ps="$ps \$ni=New-Object System.Windows.Forms.NotifyIcon;"
        ps="$ps \$ni.Icon=[System.Drawing.SystemIcons]::Information;"
        ps="$ps \$ni.Visible=\$true;"
        ps="$ps \$ni.ShowBalloonTip(5000,'$t','$b','Info');"
        ps="$ps Start-Sleep -Seconds 5; \$ni.Dispose() }"
        spawn powershell.exe -NoProfile -NonInteractive -Command "$ps"
        return 0
      fi
      ;;
  esac

  # Generic: notify-send (Linux), then osascript as a last resort.
  if command -v notify-send >/dev/null 2>&1; then
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

show_toast "$title" "$body" "$icon" "$urgency" "ccns-$proj"
[ -n "$sound" ] && play_detached "$sound" "$VOL"

# ALWAYS exit 0. This runs on the Stop hook, where a nonzero status is reported
# as a hook failure — and on Claude Code's Stop event an exit status of 2 means
# "do not end the turn". Without this line the script's status came from the
# `[ -n "$sound" ]` test above, so a silent (empty) sound folder — the state of
# every folder on a fresh clone — made every event exit 1.
exit 0
