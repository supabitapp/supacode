#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script_path="${script_dir}/$(basename "${BASH_SOURCE[0]}")"
srcroot="${SRCROOT:-$(cd "${script_dir}/.." && pwd)}"
repo_root="${srcroot}"
zmx_dir="${srcroot}/ThirdParty/zmx"
zmx_submodule_path="${zmx_dir#"${repo_root}/"}"
zmx_build_root="${srcroot}/.build/zmx"
zmx_local_cache_dir="${zmx_build_root}/.zig-cache"
zmx_global_cache_dir="${zmx_build_root}/.zig-global-cache"
zmx_fingerprint_path="${zmx_build_root}/fingerprint"
zmx_binary_path="${zmx_build_root}/bin/zmx"

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

if [ -f "${zmx_fingerprint_path}" ] &&
  [ -x "${zmx_binary_path}" ] &&
  [ "$(cat "${zmx_fingerprint_path}")" = "${fingerprint}" ]; then
  exit 0
fi

cd "${zmx_dir}"
mise exec -- zig build -Doptimize=ReleaseSafe --prefix "${zmx_build_root}" --cache-dir "${zmx_local_cache_dir}" --global-cache-dir "${zmx_global_cache_dir}"

if [ ! -x "${zmx_binary_path}" ]; then
  echo "error: zmx build produced no binary at ${zmx_binary_path}" >&2
  exit 1
fi

printf '%s\n' "${fingerprint}" > "${zmx_fingerprint_path}"
