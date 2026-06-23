#!/usr/bin/env bash
# Prints the Contents/Developer path of an Xcode whose macOS SDK can be linked
# by the pinned Zig (0.15.2, required exactly by ghostty). Used by the ghostty /
# zmx build scripts, the Makefile build targets, and `make doctor` so they all
# agree on one toolchain — without a global `sudo xcode-select -s`.
#
# Exit 0 + print the chosen dir on success; exit 1 + actionable message on stderr
# when no linkable Xcode is installed.
set -euo pipefail

# True if the given Developer dir's macOS SDK still exports the plain
# `arm64-macos` target that Zig 0.15.2's self-hosted linker needs. macOS 26.4+
# SDKs dropped it (keeping only `arm64e-macos`), which makes `zig build` fail
# with `undefined symbol: _malloc, _free, ...` in build_zcu.o — ziglang/zig
# #31658, fixed only in Zig 0.16+. We probe with the `--sdk macosx` form Zig
# itself uses; plain `xcrun --show-sdk-path` can resolve to the CommandLineTools
# SDK instead of the active Xcode's and give a misleading answer.
is_zig_linkable() {
  local dir="$1" sdk tbd
  [ -d "$dir" ] || return 1
  sdk="$(DEVELOPER_DIR="$dir" xcrun --sdk macosx --show-sdk-path 2>/dev/null)" || return 1
  [ -n "$sdk" ] || return 1
  tbd="$sdk/usr/lib/libSystem.tbd"
  [ -f "$tbd" ] || return 1
  # `arm64-macos` does not match `arm64e-macos` (the broken SDK) — that mismatch
  # is exactly the signal we want.
  grep -q 'arm64-macos' "$tbd"
}

# Honor an explicit DEVELOPER_DIR when it is itself linkable (escape hatch:
# `DEVELOPER_DIR=… make build-app`).
if [ -n "${DEVELOPER_DIR:-}" ] && is_zig_linkable "${DEVELOPER_DIR}"; then
  printf '%s\n' "${DEVELOPER_DIR}"
  exit 0
fi

candidates=()
# Whatever is currently selected first, so a machine where the default Xcode is
# already linkable needs zero configuration.
if current="$(xcode-select -p 2>/dev/null)" && [ -n "${current}" ]; then
  candidates+=("${current}")
fi
# Then versioned Xcodes newest-first, then the unversioned default. 26.3 is the
# newest that ships a Zig-linkable SDK (the macOS 26.2 SDK).
for app in /Applications/Xcode_26.3*.app /Applications/Xcode_26.2*.app \
  /Applications/Xcode_26.1*.app /Applications/Xcode_26.0*.app /Applications/Xcode.app; do
  [ -d "${app}" ] && candidates+=("${app}/Contents/Developer")
done

for dir in "${candidates[@]}"; do
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

  No global `xcode-select -s` is needed — the build picks it up automatically.
EOF
exit 1
