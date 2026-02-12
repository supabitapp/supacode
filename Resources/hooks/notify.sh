#!/usr/bin/env bash
set -euo pipefail

surface_id="${SUPACODE_SURFACE_ID:-}"
if [[ -z "$surface_id" ]]; then
  exit 0
fi

signals_dir="$HOME/.supacode/hooks/signals"
mkdir -p "$signals_dir"
signal_file="$signals_dir/$surface_id"

if [[ $# -gt 0 ]]; then
  payload="$1"
else
  payload="$(cat)"
fi

event_name="$({
  printf '%s' "$payload" \
    | grep -oE '"hook_event_name"[[:space:]]*:[[:space:]]*"[^"]*"' \
    | sed -E 's/.*"hook_event_name"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/' \
    | head -n 1
} || true)"

if [[ -z "$event_name" ]]; then
  event_name="$({
    printf '%s' "$payload" \
      | grep -oE '"type"[[:space:]]*:[[:space:]]*"[^"]*"' \
      | sed -E 's/.*"type"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/' \
      | head -n 1
  } || true)"
fi

case "$event_name" in
  UserPromptSubmit|Start|agent-turn-start)
    printf 'working\n' > "$signal_file"
    ;;
  Stop|agent-turn-complete)
    rm -f "$signal_file"
    ;;
  *)
    ;;
esac
