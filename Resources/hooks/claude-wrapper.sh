#!/usr/bin/env bash
set -euo pipefail

hooks_bin="${HOME}/.supacode/hooks/bin"
hooks_bin="${hooks_bin%/}"
wrapper_path="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
real_claude=""
IFS=':' read -r -a path_parts <<< "${PATH:-}"

for path_part in "${path_parts[@]}"; do
  if [[ -z "$path_part" ]]; then
    continue
  fi
  path_part="${path_part%/}"
  if [[ "$path_part" == "$hooks_bin" ]]; then
    continue
  fi
  candidate="$path_part/claude"
  if [[ "$candidate" == "$wrapper_path" ]]; then
    continue
  fi
  if [[ -x "$candidate" ]]; then
    real_claude="$candidate"
    break
  fi
done

if [[ -z "$real_claude" ]]; then
  echo "supacode: unable to locate real claude binary" >&2
  exit 1
fi

surface_id="${SUPACODE_SURFACE_ID:-}"
signal_file=""
if [[ -n "$surface_id" ]]; then
  signal_file="$HOME/.supacode/hooks/signals/$surface_id"
fi

cleanup_signal() {
  if [[ -n "$signal_file" ]]; then
    rm -f "$signal_file"
  fi
}

child_pid=""
forward_signal() {
  local signal="$1"
  if [[ -n "$child_pid" ]]; then
    kill "-$signal" "$child_pid" 2>/dev/null || true
  fi
}

trap cleanup_signal EXIT
trap 'forward_signal INT; exit 130' INT
trap 'forward_signal TERM; exit 143' TERM
trap 'forward_signal HUP; exit 129' HUP
trap 'forward_signal QUIT; exit 131' QUIT

"$real_claude" --settings "$HOME/.supacode/hooks/claude-settings.json" "$@" &
child_pid=$!

exit_code=0
if ! wait "$child_pid"; then
  exit_code=$?
fi
child_pid=""
exit "$exit_code"
