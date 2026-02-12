#!/usr/bin/env bash
set -euo pipefail

hooks_bin="$HOME/.supacode/hooks/bin"
real_claude=""
IFS=':' read -r -a path_parts <<< "${PATH:-}"

for path_part in "${path_parts[@]}"; do
  if [[ -z "$path_part" ]]; then
    continue
  fi
  if [[ "$path_part" == "$hooks_bin" ]]; then
    continue
  fi
  candidate="$path_part/claude"
  if [[ -x "$candidate" ]]; then
    real_claude="$candidate"
    break
  fi
done

if [[ -z "$real_claude" ]]; then
  echo "supacode: unable to locate real claude binary" >&2
  exit 1
fi

exec "$real_claude" --settings "$HOME/.supacode/hooks/claude-settings.json" "$@"
