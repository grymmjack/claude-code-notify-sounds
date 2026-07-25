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

set -u

# ---- config -----------------------------------------------------------------
SELF="$(readlink -f "$0" 2>/dev/null || echo "$0")"
SELF_DIR="$(cd "$(dirname "$SELF")" && pwd)"
SNDDIR="${CLAUDE_NOTIFY_SOUNDS:-$SELF_DIR/sounds}"   # override with an env var
VOL="${CLAUDE_NOTIFY_VOLUME:-0.35}"                  # 0.0 (silent) .. 1.0 (full)
APPNAME="Claude Code"
# -----------------------------------------------------------------------------

spawn() {   # run a command detached so it outlives this short-lived hook
  if command -v setsid >/dev/null 2>&1; then setsid -f "$@" >/dev/null 2>&1 && return 0; fi
  ( "$@" >/dev/null 2>&1 & )
}

play_detached() {   # play $1 at volume $2 via the first available player
  local f="$1" vol="$2"
  [ -r "$f" ] || return 0
  if   command -v pw-play >/dev/null 2>&1; then spawn pw-play --volume "$vol" "$f"
  elif command -v paplay  >/dev/null 2>&1; then spawn paplay --volume "$(awk -v v="$vol" 'BEGIN{printf "%d", v*65536}')" "$f"
  elif command -v ffplay  >/dev/null 2>&1; then spawn ffplay -nodisp -autoexit -loglevel quiet "$f"
  elif command -v afplay  >/dev/null 2>&1; then spawn afplay -v "$vol" "$f"     # macOS
  elif command -v aplay   >/dev/null 2>&1; then spawn aplay -q "$f"             # no volume control
  fi
}

show_toast() {   # $1 title  $2 body  $3 icon  $4 urgency  $5 dedup-tag
  if command -v notify-send >/dev/null 2>&1; then
    notify-send --app-name="$APPNAME" --urgency="$4" --icon="$3" \
      -h "string:x-canonical-private-synchronous:$5" \
      -h "string:suppress-sound:true" \
      "$1" "$2" >/dev/null 2>&1 || true
  elif command -v osascript >/dev/null 2>&1; then   # macOS fallback
    osascript -e "display notification \"$2\" with title \"$1\"" >/dev/null 2>&1 || true
  fi
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

# NOTIFY_DEBUG=1 prints the selection to stderr (handy for testing).
[ -n "${NOTIFY_DEBUG:-}" ] && printf 'notify.sh %-9s -> %s\n' "$event" "$(basename "${sound:-none}")" >&2

show_toast "$title" "$body" "$icon" "$urgency" "ccns-$proj"
[ -n "$sound" ] && play_detached "$sound" "$VOL"
