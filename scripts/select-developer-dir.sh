#!/usr/bin/env bash
# Prints the Developer dir of a full Xcode for `zig build`'s SDK lookups. Shared by
# the build scripts, the Makefile, and `make doctor`. Exit 1 with an actionable
# message when none is installed.
set -euo pipefail

# The app targets macOS 26, so older SDKs fail deep inside the build instead.
min_sdk_version="26.0"

# Usable when the dir is a full Xcode (not CommandLineTools, which has no
# xcodebuild) whose macOS SDK is at least the minimum.
is_usable_xcode() {
  local dir="$1" ver
  [ -d "$dir" ] || return 1
  [ -x "${dir}/usr/bin/xcodebuild" ] || return 1
  ver="$(DEVELOPER_DIR="$dir" xcrun --sdk macosx --show-sdk-version 2>/dev/null)" || return 1
  [ -n "$ver" ] || return 1
  [ "$(printf '%s\n%s\n' "$min_sdk_version" "$ver" | sort -V | head -1)" = "$min_sdk_version" ]
}

if [ -n "${DEVELOPER_DIR:-}" ]; then
  if is_usable_xcode "${DEVELOPER_DIR}"; then
    printf '%s\n' "${DEVELOPER_DIR}"
    exit 0
  fi
  echo "warning: DEVELOPER_DIR=${DEVELOPER_DIR} is not a usable Xcode; looking for another." >&2
fi

candidates=()
if current="$(xcode-select -p 2>/dev/null)" && [ -n "${current}" ]; then
  candidates+=("${current}")
fi
# Side-by-side installs (Xcode_27.app, Xcode-beta.app), newest name first.
while IFS= read -r app; do
  [ -n "${app}" ] && candidates+=("${app}/Contents/Developer")
done < <(ls -d /Applications/Xcode*.app 2>/dev/null | sort -rV)

# Guard the empty case: bash 3.2 errors on `"${arr[@]}"` under `set -u`.
for dir in ${candidates[@]+"${candidates[@]}"}; do
  if is_usable_xcode "${dir}"; then
    printf '%s\n' "${dir}"
    exit 0
  fi
done

cat >&2 <<EOF
error: no usable Xcode found (a full Xcode with the macOS ${min_sdk_version}+ SDK).

  Install Xcode from the App Store. If it is already installed, accept its
  license and finish first launch:

    sudo xcodebuild -license accept
    sudo xcodebuild -runFirstLaunch
EOF
exit 1
