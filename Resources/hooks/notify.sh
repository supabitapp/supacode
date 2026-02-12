#!/usr/bin/env bash
set -euo pipefail

surface_id="${SUPACODE_SURFACE_ID:-}"
if [[ -z "$surface_id" ]]; then
  exit 0
fi

signals_dir="$HOME/.supacode/hooks/signals"
mkdir -p "$signals_dir"
signal_file="$signals_dir/$surface_id"
payload="$(cat)"
event_name="$({
  printf '%s' "$payload" \
    | grep -o '"hook_event_name"[[:space:]]*:[[:space:]]*"[^"]*"' \
    | sed 's/.*"hook_event_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' \
    | head -n 1
} || true)"

case "$event_name" in
  UserPromptSubmit)
    printf 'working\n' > "$signal_file"
    ;;
  Stop)
    rm -f "$signal_file"
    ;;
  *)
    ;;
esac
