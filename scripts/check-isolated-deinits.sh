#!/usr/bin/env bash
# Fails when an unstripped binary holds an isolated deinit, which aborts on
# macOS 26.3 and earlier (#853). Drop once the deployment target is 26.4+.
#
# Usage: scripts/check-isolated-deinits.sh <binary>...
set -euo pipefail

# Generated resource-bundle lookups, never instantiated.
allowlist=(
  "SupacodeSettingsShared.(BundleFinder in _"
  "SupacodeSettingsShared.SupacodeSettingsSharedResources."
  "supacode.(BundleFinder in _"
  "supacode.(ResourceBundleClass in _"
  "supacode.SupacodeResources."
)

is_allowlisted() {
  local entry
  for entry in "${allowlist[@]}"; do
    [[ "$1" == "${entry}"* ]] && return 0
  done
  return 1
}

if [ "$#" -eq 0 ]; then
  echo "usage: check-isolated-deinits.sh <binary>..." >&2
  exit 2
fi

nm_errors="$(mktemp)"
trap 'rm -f "${nm_errors}"' EXIT

violations=""
for binary in "$@"; do
  if [ ! -f "${binary}" ]; then
    echo "error: missing ${binary}" >&2
    exit 1
  fi
  if ! symbols="$(nm -j "${binary}" 2>"${nm_errors}")"; then
    echo "error: nm failed on ${binary}: $(cat "${nm_errors}")" >&2
    exit 1
  fi
  # `fZ` mangles `__isolated_deallocating_deinit`.
  isolated="$(grep 'fZ$' <<<"${symbols}" || true)"
  [ -z "${isolated}" ] && continue
  demangled="$(xcrun swift-demangle <<<"${isolated}" | sort -u)"
  while IFS= read -r symbol; do
    is_allowlisted "${symbol}" && continue
    violations+="  ${symbol%.__isolated_deallocating_deinit}"$'\n'
  done <<<"${demangled}"
done

if [ -n "${violations}" ]; then
  echo "error: isolated deinits abort on macOS 26.3 and earlier when released in a task-local scope (#853)." >&2
  echo "Add \`nonisolated deinit {}\` (wrap a body touching main-actor state in \`MainActor.assumeIsolated\`) to:" >&2
  printf '%s' "${violations}" >&2
  exit 1
fi
