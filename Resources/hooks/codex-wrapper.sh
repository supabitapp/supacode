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
signal_file=""
if [[ -n "$surface_id" ]]; then
  signals_dir="${SUPACODE_HOOK_SIGNALS_DIR:-${TMPDIR:-/tmp}/supacode-agent-hooks/signals}"
  mkdir -p "$signals_dir"
  signal_file="$signals_dir/$surface_id"
  printf 'working\n' > "$signal_file"
fi

cleanup_signal() {
  if [[ -n "$signal_file" ]]; then
    rm -f "$signal_file"
  fi
}

trap cleanup_signal EXIT
"$real_codex" -c "notify=[\"bash\",\"$HOME/.supacode/hooks/notify.sh\"]" "$@"
