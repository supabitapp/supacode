#!/usr/bin/env bash
set -euo pipefail

wt_script="${SRCROOT}/Resources/git-wt/wt"
if [ ! -f "${wt_script}" ]; then
  echo "error: missing ${wt_script}. run: git submodule update --init Resources/git-wt" >&2
  exit 1
fi

if [ ! -x "${wt_script}" ]; then
  echo "error: ${wt_script} is not executable" >&2
  exit 1
fi

# The bundled wt carries a build-time patch (see embed-runtime-assets.sh). Fail
# early here if the pinned submodule drifted so the patch no longer applies,
# rather than deep in the resource-copy phase. #616.
patch_file="${SRCROOT}/patches/git-wt/git-wt-canonical-worktree-path.patch"
if [ ! -f "${patch_file}" ]; then
  echo "error: missing ${patch_file}" >&2
  exit 1
fi
check_dir=$(mktemp -d)
trap 'rm -rf "${check_dir}"' EXIT
cp "${wt_script}" "${check_dir}/wt"
if ! (cd "${check_dir}" && GIT_DIR=/dev/null git apply --check -p1 "${patch_file}"); then
  echo "error: ${patch_file} no longer applies to the pinned wt; refresh it after the git-wt bump" >&2
  exit 1
fi
