#!/usr/bin/env bash
# Prints the "hooks" block for ~/.claude/settings.json with this repo's
# absolute notify.sh path filled in.
#
#   ./install.sh                 # print the ready-to-paste JSON
#   ./install.sh | jq .          # pretty-print / validate
#
# Then MERGE the output into ~/.claude/settings.json under "hooks" — do NOT
# replace an existing "hooks" object; add these keys alongside what's there.
# If you already have a SessionStart hook, put this one in the same hooks array.
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
sed "s|__NOTIFY_SH__|$DIR/notify.sh|g" "$DIR/hooks.settings.json"
