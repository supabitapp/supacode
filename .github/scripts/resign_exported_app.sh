#!/usr/bin/env bash
set -euo pipefail

: "${DEVELOPER_ID_IDENTITY_SHA:?}"

export_root=${1:?}
app_path=$(find "$export_root" -maxdepth 3 -name 'supacode.app' -print -quit)
if [ -z "$app_path" ]; then
  echo "::error::supacode.app not found under $export_root"
  exit 1
fi

sign_path() {
  local path=$1
  local -a args=(-f -s "$DEVELOPER_ID_IDENTITY_SHA" -o runtime --timestamp -v)

  case "$path" in
    *.app|*.appex|*.xpc)
      args+=(--preserve-metadata=entitlements,requirements,flags)
      ;;
  esac

  codesign "${args[@]}" "$path"
}

code_roots=(
  "$app_path/Contents/Frameworks"
  "$app_path/Contents/PlugIns"
  "$app_path/Contents/Resources"
  "$app_path/Contents/XPCServices"
  "$app_path/Contents/Library/LoginItems"
)

code_paths=()
for root in "${code_roots[@]}"; do
  if [ ! -d "$root" ]; then
    continue
  fi

  while IFS= read -r -d '' path; do
    code_paths+=("$path")
  done < <(
    find "$root" \
      \( -type d \( -name '*.app' -o -name '*.appex' -o -name '*.framework' -o -name '*.xpc' \) \
      -o -type f \( -name '*.dylib' -o -perm -111 \) \) \
      -print0
  )
done

if [ "${#code_paths[@]}" -gt 0 ]; then
  while IFS=$'\t' read -r _ path; do
    sign_path "$path"
  done < <(
    for path in "${code_paths[@]}"; do
      slash_count=${path//[^\/]/}
      printf '%s\t%s\n' "${#slash_count}" "$path"
    done | sort -rn -k1,1
  )
fi

codesign -f -s "$DEVELOPER_ID_IDENTITY_SHA" -o runtime --timestamp --preserve-metadata=entitlements,requirements,flags -v "$app_path"
codesign -vvv --deep --strict "$app_path"
