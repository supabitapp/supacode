#!/usr/bin/env bash
# Prints the Developer dir of a full Xcode for `zig build`'s SDK lookups. Shared by
# the build scripts, the Makefile, and `make doctor`. Exit 1 with an actionable
# message when none is installed.
set -euo pipefail

# Usable when the dir is a full Xcode (not CommandLineTools, which has no
# xcodebuild) with a macOS SDK.
is_usable_xcode() {
  local dir="$1"
  [ -d "$dir" ] || return 1
  [ -x "${dir}/usr/bin/xcodebuild" ] || return 1
  [ -n "$(DEVELOPER_DIR="$dir" xcrun --sdk macosx --show-sdk-version 2>/dev/null)" ]
}

candidates=()
[ -n "${DEVELOPER_DIR:-}" ] && candidates+=("${DEVELOPER_DIR}")
if current="$(xcode-select -p 2>/dev/null)" && [ -n "${current}" ]; then
  candidates+=("${current}")
fi
[ -d /Applications/Xcode.app ] && candidates+=("/Applications/Xcode.app/Contents/Developer")

# Guard the empty case: bash 3.2 errors on `"${arr[@]}"` under `set -u`.
for dir in ${candidates[@]+"${candidates[@]}"}; do
  if is_usable_xcode "${dir}"; then
    printf '%s\n' "${dir}"
    exit 0
  fi
done

cat >&2 <<'EOF'
error: no Xcode found.

  Install Xcode from the App Store, then accept its license and finish first
  launch:

    sudo xcodebuild -license accept
    sudo xcodebuild -runFirstLaunch
EOF
exit 1
