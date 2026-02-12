#!/usr/bin/env bash
set -euo pipefail

hooks_bin="$HOME/.supacode/hooks/bin"
real_codex=""
IFS=':' read -r -a path_parts <<< "${PATH:-}"

for path_part in "${path_parts[@]}"; do
  if [[ -z "$path_part" ]]; then
    continue
  fi
  if [[ "$path_part" == "$hooks_bin" ]]; then
    continue
  fi
  candidate="$path_part/codex"
  if [[ -x "$candidate" ]]; then
    real_codex="$candidate"
    break
  fi
done

if [[ -z "$real_codex" ]]; then
  echo "supacode: unable to locate real codex binary" >&2
  exit 1
fi

exec "$real_codex" -c "notify=[\"bash\",\"$HOME/.supacode/hooks/notify.sh\"]" "$@"
