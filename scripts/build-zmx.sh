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

ensure_zmx_checkout

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
