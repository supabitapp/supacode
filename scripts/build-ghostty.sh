#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script_path="${script_dir}/$(basename "${BASH_SOURCE[0]}")"
srcroot="${SRCROOT:-$(cd "${script_dir}/.." && pwd)}"
repo_root="${srcroot}"

# Pin a Zig-linkable Xcode for `zig build`'s SDK lookups (see select-developer-dir.sh).
# Always delegate so an inherited DEVELOPER_DIR is validated, not trusted blindly.
# Plain assignment, separate export, so a selector failure aborts under set -e.
DEVELOPER_DIR="$("${script_dir}/select-developer-dir.sh")"
export DEVELOPER_DIR
ghostty_dir="${srcroot}/ThirdParty/ghostty"
ghostty_submodule_path="${ghostty_dir#"${repo_root}/"}"
ghostty_build_root="${srcroot}/.build/ghostty"
ghostty_local_cache_dir="${ghostty_build_root}/.zig-cache"
ghostty_global_cache_dir="${ghostty_build_root}/.zig-global-cache"
ghostty_fingerprint_path="${ghostty_build_root}/fingerprint"
ghostty_legacy_prefix_path="${ghostty_dir}/zig-out"
ghostty_legacy_share_path="${ghostty_legacy_prefix_path}/share"
xcframework_path="${ghostty_build_root}/GhosttyKit.xcframework"
ghostty_resources_path="${ghostty_build_root}/share/ghostty"
ghostty_terminfo_path="${ghostty_build_root}/share/terminfo"
# Out-of-tree patches applied to the pinned ghostty submodule at build time.
# The submodule pointer stays on upstream; we never fork or commit into it.
ghostty_patches_dir="${srcroot}/patches"

print_fingerprint() {
  (
    cd "${ghostty_dir}"
    {
      git rev-parse HEAD
      git diff --no-ext-diff --no-color HEAD -- . | shasum -a 256
      git ls-files --others --exclude-standard | LC_ALL=C sort | shasum -a 256
      shasum -a 256 "${script_path}" | awk '{print $1}'
      shasum -a 256 "${srcroot}/mise.toml" | awk '{print $1}'
    } | shasum -a 256 | awk '{print $1}'
  )
}

prepare_xcframework() {
  local modulemap
  find "${xcframework_path}" -path '*/Headers/module.modulemap' -print0 | while IFS= read -r -d '' modulemap; do
    cat > "${modulemap}" <<'EOF'
module GhosttyKit {
    header "ghostty.h"
    export *
}
EOF
  done
}

ensure_ghostty_checkout() {
  if [ -f "${ghostty_dir}/build.zig" ]; then
    return
  fi

  git -C "${repo_root}" submodule sync --recursive -- "${ghostty_submodule_path}"
  git -C "${repo_root}" submodule update --init --recursive -- "${ghostty_submodule_path}"

  if [ ! -f "${ghostty_dir}/build.zig" ]; then
    echo "error: missing ${ghostty_dir} after submodule update" >&2
    exit 1
  fi
}

# Apply our out-of-tree patches to the submodule working tree. Idempotent: a
# patch that already applies in reverse is treated as present. Fails loudly if
# a patch no longer applies (e.g. after an upstream bump) so it's never silently
# skipped. The submodule's committed SHA is untouched; `revert_ghostty_patches`
# restores a pristine working tree on exit.
# Repo-relative paths a patch touches. Parses the patch itself, not the tree, so
# it works even when the working tree is dirty.
ghostty_patch_files() {
  git -C "${ghostty_dir}" apply --numstat "$1" 2>/dev/null | awk '{ print $3 }'
}

# Reset just the files a patch touches back to the pinned SHA. Reads the file
# list line by line (bash 3.2 compatible) so a path with spaces stays intact.
reset_ghostty_patch_files() {
  local f
  local files=()
  while IFS= read -r f; do
    [ -n "${f}" ] && files+=("${f}")
  done < <(ghostty_patch_files "$1")
  [ "${#files[@]}" -eq 0 ] || git -C "${ghostty_dir}" checkout -- "${files[@]}" 2>/dev/null || true
}

apply_ghostty_patches() {
  [ -d "${ghostty_patches_dir}" ] || return 0
  local patch
  for patch in "${ghostty_patches_dir}"/*.patch; do
    [ -e "${patch}" ] || continue
    if git -C "${ghostty_dir}" apply --reverse --check "${patch}" 2>/dev/null; then
      continue # already fully applied
    fi
    if ! git -C "${ghostty_dir}" apply --check "${patch}" 2>/dev/null; then
      # Neither pristine nor cleanly applied: most likely a prior build was killed
      # (SIGKILL / power loss) mid-apply and left the patched files dirty. Reset
      # just those files to the pinned SHA and retry before blaming an upstream bump.
      reset_ghostty_patch_files "${patch}"
      if ! git -C "${ghostty_dir}" apply --check "${patch}" 2>/dev/null; then
        echo "error: ${patch} does not apply cleanly to ${ghostty_submodule_path}." >&2
        echo "       The submodule may have been bumped (refresh the patch), or a" >&2
        echo "       previous build left it dirty: git -C ${ghostty_submodule_path} checkout . && retry." >&2
        exit 1
      fi
    fi
    git -C "${ghostty_dir}" apply "${patch}"
  done
}

revert_ghostty_patches() {
  [ -d "${ghostty_patches_dir}" ] || return 0
  local patch
  for patch in "${ghostty_patches_dir}"/*.patch; do
    [ -e "${patch}" ] || continue
    # Prefer a clean reverse-apply; fall back to resetting just the patched files.
    # The fallback also guards against `set -e` aborting the trap mid-revert if the
    # reverse-apply fails (e.g. a partially-applied tree).
    if git -C "${ghostty_dir}" apply --reverse --check "${patch}" 2>/dev/null; then
      git -C "${ghostty_dir}" apply --reverse "${patch}" 2>/dev/null || reset_ghostty_patch_files "${patch}"
    else
      reset_ghostty_patch_files "${patch}"
    fi
  done
}

ensure_ghostty_checkout

# Patch the pinned submodule in place for this build only, restoring it on exit
# so `git status` stays clean and the pin is never disturbed. Applied before the
# fingerprint so patched source is reflected in the rebuild trigger.
#
# Revert on signals too (not just EXIT): a cancelled Xcode build or Ctrl-C sends
# SIGINT/SIGTERM, which would otherwise skip the EXIT trap and leave the tree
# patched (dirty status + poisoned fingerprint). On signal we revert, clear the
# traps to avoid a double revert, and exit with the conventional 128+signal code.
revert_and_signal_exit() {
  revert_ghostty_patches
  trap - EXIT INT TERM
  case "$1" in
    TERM) exit 143 ;;
    *) exit 130 ;;
  esac
}
trap revert_ghostty_patches EXIT
trap 'revert_and_signal_exit INT' INT
trap 'revert_and_signal_exit TERM' TERM
apply_ghostty_patches

if [ "${1:-}" = "--print-fingerprint" ]; then
  print_fingerprint
  exit 0
fi

fingerprint="$(print_fingerprint)"

rm -rf "${ghostty_legacy_prefix_path}"
mkdir -p "${ghostty_build_root}" "${ghostty_legacy_prefix_path}"
ln -s "${ghostty_build_root}/share" "${ghostty_legacy_share_path}"

if [ -f "${ghostty_fingerprint_path}" ] &&
  [ -d "${xcframework_path}" ] &&
  [ -d "${ghostty_resources_path}" ] &&
  [ -d "${ghostty_terminfo_path}" ] &&
  [ "$(cat "${ghostty_fingerprint_path}")" = "${fingerprint}" ]; then
  exit 0
fi

cd "${ghostty_dir}"
mise exec -- zig build -Doptimize=ReleaseFast -Demit-xcframework=true -Dsentry=false --prefix "${ghostty_build_root}" --cache-dir "${ghostty_local_cache_dir}" --global-cache-dir "${ghostty_global_cache_dir}"
rsync -a --delete "${ghostty_dir}/macos/GhosttyKit.xcframework/" "${xcframework_path}/"
prepare_xcframework
printf '%s\n' "${fingerprint}" > "${ghostty_fingerprint_path}"
