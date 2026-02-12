#!/usr/bin/env bash
set -euo pipefail

surface_id="${SUPACODE_SURFACE_ID:-}"
if [[ -z "$surface_id" ]]; then
  exit 0
fi

signals_dir="${SUPACODE_HOOK_SIGNALS_DIR:-${TMPDIR:-/tmp}/supacode-agent-hooks/signals}"
mkdir -p "$signals_dir"
signal_file="$signals_dir/$surface_id"
log_path="${SUPACODE_HOOK_LOG_PATH:-}"

log_line() {
  if [[ -n "$log_path" ]]; then
    mkdir -p "$(dirname "$log_path")"
    printf '%s notify %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" >> "$log_path"
  fi
}

if [[ $# -gt 0 ]]; then
  payload="$*"
else
  payload="$(cat)"
fi

hook_event_name="$({
  printf '%s' "$payload" \
    | grep -oE '"hook_event_name"[[:space:]]*:[[:space:]]*"[^"]*"' \
    | sed -E 's/.*"hook_event_name"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/' \
    | head -n 1
} || true)"

type_event_name="$({
  printf '%s' "$payload" \
    | grep -oE '"type"[[:space:]]*:[[:space:]]*"[^"]*"' \
    | sed -E 's/.*"type"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/' \
    | head -n 1
} || true)"

event_name="$hook_event_name"
if [[ -z "$event_name" ]]; then
  event_name="$type_event_name"
fi

log_line "surface=$surface_id event=$event_name hook=$hook_event_name type=$type_event_name"

case "$event_name" in
  UserPromptSubmit|Start|agent-turn-start)
    printf 'working\n' > "$signal_file"
    log_line "state=working surface=$surface_id"
    ;;
  Stop|agent-turn-complete)
    rm -f "$signal_file"
    log_line "state=idle surface=$surface_id"
    ;;
  *)
    ;;
esac
