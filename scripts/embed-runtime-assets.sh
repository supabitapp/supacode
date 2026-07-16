#!/usr/bin/env bash
set -euo pipefail

destination_root="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
git_wt_source="${SRCROOT}/Resources/git-wt/wt"
git_wt_patch="${SRCROOT}/patches/git-wt/git-wt-canonical-worktree-path.patch"
zmx_source="${SRCROOT}/.build/zmx/bin/zmx"
light_theme_source="${SRCROOT}/supacode/Resources/Themes/Supacode Light"
dark_theme_source="${SRCROOT}/supacode/Resources/Themes/Supacode Dark"
git_wt_destination_dir="${destination_root}/git-wt"
zmx_destination_dir="${destination_root}/zmx"
bin_destination_dir="${destination_root}/bin"
cli_candidates=(
  "${BUILT_PRODUCTS_DIR}/supacode"
  "${UNINSTALLED_PRODUCTS_DIR}/${PLATFORM_NAME}/supacode"
)

cli_source=""
for candidate in "${cli_candidates[@]}"; do
  if [ -x "${candidate}" ]; then
    cli_source="${candidate}"
    break
  fi
done

if [ -z "${cli_source}" ]; then
  echo "error: missing built supacode executable" >&2
  exit 1
fi

if [ ! -x "${zmx_source}" ]; then
  echo "error: missing ${zmx_source}. run: make build-zmx" >&2
  exit 1
fi

rm -rf "${git_wt_destination_dir}" "${zmx_destination_dir}" "${bin_destination_dir}"
mkdir -p "${git_wt_destination_dir}" "${zmx_destination_dir}" "${bin_destination_dir}"
/bin/cp -f "${git_wt_source}" "${git_wt_destination_dir}/wt"
# Ship the wt fix as a build-time patch so the fork-less submodule stays
# pristine. GIT_DIR=/dev/null stops `git apply` from discovering the surrounding
# repo, which otherwise makes it silently skip since the build output lives in
# the work tree. The grep asserts the patch landed so a stale patch fails the
# build. #616.
(cd "${git_wt_destination_dir}" && GIT_DIR=/dev/null git apply -p1 "${git_wt_patch}")
if ! grep -qF 'physical=$(cd "$path" 2>/dev/null && pwd -P)' "${git_wt_destination_dir}/wt"; then
  echo "error: ${git_wt_patch} did not apply to the bundled wt (refresh it after a git-wt bump)" >&2
  exit 1
fi
chmod +x "${git_wt_destination_dir}/wt"
/bin/cp -f "${zmx_source}" "${zmx_destination_dir}/zmx"
chmod +x "${zmx_destination_dir}/zmx"
/bin/cp -f "${light_theme_source}" "${destination_root}/Supacode Light"
/bin/cp -f "${dark_theme_source}" "${destination_root}/Supacode Dark"
/bin/cp -f "${cli_source}" "${bin_destination_dir}/supacode"
