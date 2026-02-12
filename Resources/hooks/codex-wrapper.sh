#!/usr/bin/env bash
set -euo pipefail

hooks_bin="${HOME}/.supacode/hooks/bin"
hooks_bin="${hooks_bin%/}"
wrapper_path="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
real_codex=""
IFS=':' read -r -a path_parts <<< "${PATH:-}"

for path_part in "${path_parts[@]}"; do
  if [[ -z "$path_part" ]]; then
    continue
  fi
  path_part="${path_part%/}"
  if [[ "$path_part" == "$hooks_bin" ]]; then
    continue
  fi
  candidate="$path_part/codex"
  if [[ "$candidate" == "$wrapper_path" ]]; then
    continue
  fi
  if [[ -x "$candidate" ]]; then
    real_codex="$candidate"
    break
  fi
done

if [[ -z "$real_codex" ]]; then
  echo "supacode: unable to locate real codex binary" >&2
  exit 1
fi

surface_id="${SUPACODE_SURFACE_ID:-}"
signals_dir="${SUPACODE_HOOK_SIGNALS_DIR:-${TMPDIR:-/tmp}/supacode-agent-hooks/signals}"
signal_file="$signals_dir/$surface_id"
log_path="${SUPACODE_HOOK_LOG_PATH:-}"

log_line() {
  if [[ -n "$log_path" ]]; then
    mkdir -p "$(dirname "$log_path")"
    printf '%s codex-wrapper %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" >> "$log_path"
  fi
}

cleanup_signal() {
  if [[ -n "$surface_id" ]]; then
    rm -f "$signal_file"
    log_line "cleanup surface=$surface_id"
  fi
}

trap cleanup_signal EXIT
log_line "start surface=$surface_id args=$*"
"$real_codex" -c "notify=[\"bash\",\"$HOME/.supacode/hooks/notify.sh\"]" "$@"
