#!/usr/bin/env bash
# Prints the Developer dir of an Xcode whose macOS SDK the pinned Zig (0.15.2) can
# link. Shared by the build scripts, the Makefile, and `make doctor`. Exit 1 with
# an actionable message when none is installed.
set -euo pipefail

# Linkable when the dir is a full Xcode whose macOS SDK predates the zig-breaking
# change. macOS 26.4+ SDKs can't link with Zig 0.15.2 (ziglang/zig#31658, fixed in
# 0.16+) even though their libSystem.tbd may still list arm64-macos, so gate on the
# SDK version, not that string (which is present on broken SDKs too).
is_zig_linkable() {
  local dir="$1" ver
  [ -d "$dir" ] || return 1
  # Require a full Xcode, not CommandLineTools (no xcodebuild).
  [ -x "${dir}/usr/bin/xcodebuild" ] || return 1
  ver="$(DEVELOPER_DIR="$dir" xcrun --sdk macosx --show-sdk-version 2>/dev/null)" || return 1
  [ -n "$ver" ] || return 1
  # Reject SDKs newer than 26.3 (the 26.4+ break); sort -V keeps 26.10 above 26.3.
  [ "$(printf '%s\n26.3\n' "$ver" | sort -V | tail -1)" = "26.3" ]
}

# Honor an explicit DEVELOPER_DIR when it is itself linkable.
if [ -n "${DEVELOPER_DIR:-}" ] && is_zig_linkable "${DEVELOPER_DIR}"; then
  printf '%s\n' "${DEVELOPER_DIR}"
  exit 0
fi

candidates=()
# Known-good versioned Xcodes first (newest <= 26.3, underscore and hyphen
# naming), so a machine whose default is a newer non-linkable Xcode (CI on 26.5)
# still finds a linkable one instead of stopping at the default.
for app in \
  /Applications/Xcode_26.3*.app /Applications/Xcode-26.3*.app \
  /Applications/Xcode_26.2*.app /Applications/Xcode-26.2*.app \
  /Applications/Xcode_26.1*.app /Applications/Xcode-26.1*.app \
  /Applications/Xcode_26.0*.app /Applications/Xcode-26.0*.app; do
  [ -d "${app}" ] && candidates+=("${app}/Contents/Developer")
done
# Then the currently-selected and unversioned default, covering a linkable Xcode
# at a non-standard path.
if current="$(xcode-select -p 2>/dev/null)" && [ -n "${current}" ]; then
  candidates+=("${current}")
fi
[ -d /Applications/Xcode.app ] && candidates+=("/Applications/Xcode.app/Contents/Developer")

# Guard the empty case: bash 3.2 errors on `"${arr[@]}"` under `set -u`.
for dir in ${candidates[@]+"${candidates[@]}"}; do
  if is_zig_linkable "${dir}"; then
    printf '%s\n' "${dir}"
    exit 0
  fi
done

cat >&2 <<'EOF'
error: no Zig-linkable Xcode found.

  The pinned Zig (0.15.2, required exactly by ghostty) cannot link the macOS
  26.4+ SDK: it dropped the arm64-macos slice from libSystem.tbd (ziglang/zig
  #31658, fixed only in Zig 0.16+). Install Xcode 26.3, which ships the macOS
  26.2 SDK whose .tbd still has arm64-macos:

    https://developer.apple.com/download/all/?q=Xcode%2026.3

  Then accept its license and finish first launch (DEVELOPER_DIR alone is not
  enough until this completes):

    sudo DEVELOPER_DIR=/Applications/Xcode_26.3.app/Contents/Developer xcodebuild -license accept
    sudo DEVELOPER_DIR=/Applications/Xcode_26.3.app/Contents/Developer xcodebuild -runFirstLaunch

  No global `xcode-select -s` is needed. The build picks it up automatically.
EOF
exit 1
