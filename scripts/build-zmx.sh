#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script_path="${script_dir}/$(basename "${BASH_SOURCE[0]}")"
srcroot="${SRCROOT:-$(cd "${script_dir}/.." && pwd)}"

# Pin a Zig-linkable Xcode for `zig build`'s SDK lookups (see select-developer-dir.sh).
# Always delegate so an inherited DEVELOPER_DIR is validated, not trusted blindly.
# Plain assignment, separate export, so a selector failure aborts under set -e.
DEVELOPER_DIR="$("${script_dir}/select-developer-dir.sh")"
export DEVELOPER_DIR
repo_root="${srcroot}"
zmx_dir="${srcroot}/ThirdParty/zmx"
zmx_submodule_path="${zmx_dir#"${repo_root}/"}"
zmx_build_root="${srcroot}/.build/zmx"
zmx_global_cache_dir="${zmx_build_root}/.zig-global-cache"
zmx_fingerprint_path="${zmx_build_root}/fingerprint"
zmx_binary_path="${zmx_build_root}/bin/zmx"
# Out-of-tree patches applied to the pinned zmx submodule at build time.
# The submodule pointer stays on the fork's SHA; we never commit into it.
zmx_patches_dir="${srcroot}/patches/zmx"

# Mirror Xcode's ARCHS_STANDARD for macOS (arm64, x86_64); resync if Configurations/Project.xcconfig pins ARCHS.
# Unconditional: every build emits both slices regardless of CONFIGURATION / ONLY_ACTIVE_ARCH.
zmx_targets=(
  "x86_64-macos"
  "aarch64-macos"
)

print_fingerprint() {
  (
    cd "${zmx_dir}"
    {
      git rev-parse HEAD
      git diff --no-ext-diff --no-color HEAD -- . | shasum -a 256
      git ls-files --others --exclude-standard | LC_ALL=C sort | shasum -a 256
      shasum -a 256 "${script_path}" | awk '{print $1}'
      shasum -a 256 "${srcroot}/mise.toml" | awk '{print $1}'
      # The patches are applied at build time, so an edited patch must bust the cache.
      for patch in "${zmx_patches_dir}"/*.patch; do
        [ -e "${patch}" ] || continue
        basename "${patch}"
        shasum -a 256 "${patch}" | awk '{print $1}'
      done | shasum -a 256
    } | shasum -a 256 | awk '{print $1}'
  )
}

ensure_zmx_checkout() {
  if [ -f "${zmx_dir}/build.zig" ]; then
    return
  fi

  git -C "${repo_root}" submodule sync --recursive -- "${zmx_submodule_path}"
  git -C "${repo_root}" submodule update --init --recursive -- "${zmx_submodule_path}"

  if [ ! -f "${zmx_dir}/build.zig" ]; then
    echo "error: missing ${zmx_dir} after submodule update" >&2
    exit 1
  fi
}

# Apply our out-of-tree patches to the submodule working tree. Idempotent: a
# patch that already applies in reverse is treated as present. Fails loudly if
# a patch no longer applies (e.g. after an upstream bump) so it's never silently
# skipped. The submodule's committed SHA is untouched; `revert_zmx_patches`
# restores a pristine working tree on exit.
# Repo-relative paths a patch touches. Parses the patch itself, not the tree, so
# it works even when the working tree is dirty.
zmx_patch_files() {
  git -C "${zmx_dir}" apply --numstat "$1" 2>/dev/null | awk '{ print $3 }'
}

# Reset just the files a patch touches back to the pinned SHA. Reads the file
# list line by line (bash 3.2 compatible) so a path with spaces stays intact.
reset_zmx_patch_files() {
  local f
  local files=()
  while IFS= read -r f; do
    [ -n "${f}" ] && files+=("${f}")
  done < <(zmx_patch_files "$1")
  [ "${#files[@]}" -eq 0 ] || git -C "${zmx_dir}" checkout -- "${files[@]}" 2>/dev/null || true
}

apply_zmx_patches() {
  [ -d "${zmx_patches_dir}" ] || return 0
  local patch
  for patch in "${zmx_patches_dir}"/*.patch; do
    [ -e "${patch}" ] || continue
    if git -C "${zmx_dir}" apply --reverse --check "${patch}" 2>/dev/null; then
      continue # already fully applied.
    fi
    if ! git -C "${zmx_dir}" apply --check "${patch}" 2>/dev/null; then
      # Neither pristine nor cleanly applied: most likely a prior build was killed
      # (SIGKILL / power loss) mid-apply and left the patched files dirty. Reset
      # just those files to the pinned SHA and retry before blaming an upstream bump.
      reset_zmx_patch_files "${patch}"
      if ! git -C "${zmx_dir}" apply --check "${patch}" 2>/dev/null; then
        echo "error: ${patch} does not apply cleanly to ${zmx_submodule_path}." >&2
        echo "       The submodule may have been bumped (refresh the patch), or a" >&2
        echo "       previous build left it dirty: git -C ${zmx_submodule_path} checkout . && retry." >&2
        exit 1
      fi
    fi
    git -C "${zmx_dir}" apply "${patch}"
  done
}

revert_zmx_patches() {
  [ -d "${zmx_patches_dir}" ] || return 0
  local patch
  for patch in "${zmx_patches_dir}"/*.patch; do
    [ -e "${patch}" ] || continue
    # Prefer a clean reverse-apply; fall back to resetting just the patched files.
    # The fallback also guards against `set -e` aborting the trap mid-revert if the
    # reverse-apply fails (e.g. a partially-applied tree).
    if git -C "${zmx_dir}" apply --reverse --check "${patch}" 2>/dev/null; then
      git -C "${zmx_dir}" apply --reverse "${patch}" 2>/dev/null || reset_zmx_patch_files "${patch}"
    else
      reset_zmx_patch_files "${patch}"
    fi
  done
}

ensure_zmx_checkout

# Patch the pinned submodule in place for this build only, restoring it on exit
# so `git status` stays clean and the pin is never disturbed. Applied before the
# fingerprint so patched source is reflected in the rebuild trigger.
#
# Revert on signals too (not just EXIT): a cancelled Xcode build or Ctrl-C sends
# SIGINT/SIGTERM, which would otherwise skip the EXIT trap and leave the tree
# patched (dirty status + poisoned fingerprint). On signal we revert, clear the
# traps to avoid a double revert, and exit with the conventional 128+signal code.
revert_and_signal_exit() {
  revert_zmx_patches
  trap - EXIT INT TERM
  case "$1" in
    TERM) exit 143 ;;
    *) exit 130 ;;
  esac
}
trap revert_zmx_patches EXIT
trap 'revert_and_signal_exit INT' INT
trap 'revert_and_signal_exit TERM' TERM
apply_zmx_patches

if [ "${1:-}" = "--print-fingerprint" ]; then
  print_fingerprint
  exit 0
fi

fingerprint="$(print_fingerprint)"

mkdir -p "${zmx_build_root}"
rm -rf "${zmx_build_root}/.zig-cache"

if [ -f "${zmx_fingerprint_path}" ] &&
  [ -x "${zmx_binary_path}" ] &&
  [ "$(cat "${zmx_fingerprint_path}")" = "${fingerprint}" ]; then
  exit 0
fi

cd "${zmx_dir}"

slice_paths=()
for target in "${zmx_targets[@]}"; do
  slice_prefix="${zmx_build_root}/slices/${target}"
  slice_cache="${slice_prefix}/.zig-cache"
  slice_binary="${slice_prefix}/bin/zmx"
  mise exec -- zig build \
    -Doptimize=ReleaseSafe \
    -Dtarget="${target}" \
    --prefix "${slice_prefix}" \
    --cache-dir "${slice_cache}" \
    --global-cache-dir "${zmx_global_cache_dir}"
  if [ ! -x "${slice_binary}" ]; then
    echo "error: zmx build produced no binary at ${slice_binary} for target ${target}" >&2
    exit 1
  fi
  slice_paths+=("${slice_binary}")
done

mkdir -p "$(dirname "${zmx_binary_path}")"
lipo -create "${slice_paths[@]}" -output "${zmx_binary_path}"

# Defense in depth: -verify_arch fails closed on a partial / thin lipo output, but exits silently.
if ! lipo "${zmx_binary_path}" -verify_arch x86_64 arm64; then
  echo "error: zmx universal binary at ${zmx_binary_path} is missing x86_64 or arm64 slice" >&2
  exit 1
fi

printf '%s\n' "${fingerprint}" > "${zmx_fingerprint_path}"
