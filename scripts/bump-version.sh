#!/usr/bin/env bash
# Bumps the version and signs the release-triggering tag. A version is required;
# minor/major bumps require a `## title\n\nbody` headline that rides the tag and
# CI prepends to the auto-generated notes.
#
# Usage: VERSION=x.y.z [BUILD=n] [TITLE=… [BODY=…]] scripts/bump-version.sh
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
config_path="${repo_root}/Configurations/Project.xcconfig"

VERSION="${VERSION:-}"
BUILD="${BUILD:-}"
TITLE="${TITLE:-}"
BODY="${BODY:-}"

current="$(/usr/bin/awk -F' = ' '/^MARKETING_VERSION = [0-9.]+$/{print $2; exit}' "$config_path")"
[ -n "$current" ] || { echo "error: MARKETING_VERSION not found in $config_path" >&2; exit 1; }
cur_major="${current%%.*}"
cur_rest="${current#*.}"
cur_minor="${cur_rest%%.*}"
cur_patch="${cur_rest#*.}"

# Require a version; suggest the next ones and bail before mutating.
if [ -z "$VERSION" ]; then
  {
    echo "error: a version is required."
    echo
    echo "current: $current"
    echo "  patch  ->  make bump-and-release VERSION=${cur_major}.${cur_minor}.$((cur_patch + 1))"
    echo "  minor  ->  make bump-and-release VERSION=${cur_major}.$((cur_minor + 1)).0"
    echo "  major  ->  make bump-and-release VERSION=$((cur_major + 1)).0.0"
    echo
    echo "re-run with one of the above."
  } >&2
  exit 1
fi

if ! echo "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "error: VERSION must be in x.y.z format" >&2
  exit 1
fi

# Reject a downgrade or no-op: CI cuts the release from the tag at HEAD.
if [ "$(printf '%s\n%s\n' "$current" "$VERSION" | sort -V | tail -1)" = "$current" ]; then
  echo "error: VERSION ($VERSION) must be greater than the current version ($current)" >&2
  exit 1
fi

# Require the config clean: the commit takes the whole file, so unrelated edits would ride into the release.
if ! git -C "$repo_root" diff --quiet -- "$config_path" || ! git -C "$repo_root" diff --cached --quiet -- "$config_path"; then
  echo "error: $config_path has uncommitted changes; commit or stash them first." >&2
  exit 1
fi

new_major="${VERSION%%.*}"
new_rest="${VERSION#*.}"
new_minor="${new_rest%%.*}"

# Same major.minor is a patch; anything else is a feature release needing a headline.
is_bugfix=0
[ "$new_major" = "$cur_major" ] && [ "$new_minor" = "$cur_minor" ] && is_bugfix=1
if [ "$new_major" != "$cur_major" ]; then kind=major; else kind=minor; fi

tag_msg_file="$(mktemp)"
trap 'rm -f "$tag_msg_file"' EXIT

# Capture the headline before mutating, so an invalid one aborts with the tree clean.
has_headline=0
if [ -n "$TITLE" ] && [ -n "$BODY" ]; then
  printf '## %s\n\n%s\n' "$TITLE" "$BODY" > "$tag_msg_file"
  has_headline=1
elif [ "$is_bugfix" -eq 0 ] || [ -n "$TITLE" ]; then
  # Author in $EDITOR when interactive; a headline we can't complete is an error, not a silent drop.
  if [ -t 0 ] && [ -t 1 ]; then
    printf '## %s\n\n' "$TITLE" > "$tag_msg_file"
    "${EDITOR:-vi}" "$tag_msg_file"
    has_headline=1
  elif [ "$is_bugfix" -eq 0 ]; then
    echo "error: $VERSION is a $kind release and requires a headline." >&2
    echo "       pass TITLE=… BODY=…, or run interactively to author it in \$EDITOR." >&2
    exit 1
  else
    echo "error: TITLE was set without BODY and there is no TTY to author the rest." >&2
    echo "       pass BODY=… too, or run interactively to author it in \$EDITOR." >&2
    exit 1
  fi
fi

# Enforce git's subject/body split: '## title', blank line, body. Without the blank
# line git folds the body into the subject and CI drops it.
if [ "$has_headline" -eq 1 ]; then
  title_line="$(/usr/bin/awk 'NR==1{print; exit}' "$tag_msg_file")"
  second_line="$(/usr/bin/awk 'NR==2{print; exit}' "$tag_msg_file")"
  title="${title_line#\#\# }"
  title_text="$(printf '%s' "$title" | tr -d '[:space:]')"
  second_text="$(printf '%s' "$second_line" | tr -d '[:space:]')"
  body_text="$(/usr/bin/awk 'NR>2 && NF' "$tag_msg_file" | tr -d '[:space:]')"
  if [ "$title" = "$title_line" ] || [ -z "$title_text" ] || [ -n "$second_text" ] || [ -z "$body_text" ]; then
    if [ "$is_bugfix" -eq 0 ]; then
      echo "error: a $kind release requires a headline: '## title', a blank line, then a non-empty body." >&2
      exit 1
    fi
    has_headline=0
  fi
fi

# Resolve the build number (auto-increment when unset).
if [ -z "$BUILD" ]; then
  build="$(/usr/bin/awk -F' = ' '/^CURRENT_PROJECT_VERSION = [0-9]+$/{print $2; exit}' "$config_path")"
  [ -n "$build" ] || { echo "error: CURRENT_PROJECT_VERSION not found" >&2; exit 1; }
  build="$((build + 1))"
elif ! echo "$BUILD" | grep -qE '^[0-9]+$'; then
  echo "error: BUILD must be an integer" >&2
  exit 1
else
  build="$BUILD"
fi

sed -i '' "s/^MARKETING_VERSION = [0-9.]*/MARKETING_VERSION = $VERSION/g" "$config_path"
sed -i '' "s/^CURRENT_PROJECT_VERSION = [0-9]*/CURRENT_PROJECT_VERSION = $build/g" "$config_path"

# sed exits 0 on no match; assert the rewrite landed.
grep -qx "MARKETING_VERSION = $VERSION" "$config_path" || { echo "error: failed to write MARKETING_VERSION" >&2; exit 1; }
grep -qx "CURRENT_PROJECT_VERSION = $build" "$config_path" || { echo "error: failed to write CURRENT_PROJECT_VERSION" >&2; exit 1; }

# Commit only the config so unrelated staged changes stay out of the release.
git -C "$repo_root" commit -S -m "bump v$VERSION" -o -- "$config_path"
# verbatim cleanup keeps the `## ` heading; default cleanup would strip it as a comment.
if [ "$has_headline" -eq 1 ]; then
  # Trailing newline keeps the appended signature on its own line, else it folds into the subject and leaks into the notes.
  [ -n "$(tail -c1 "$tag_msg_file")" ] && printf '\n' >> "$tag_msg_file"
  git -C "$repo_root" tag -s --cleanup=verbatim -F "$tag_msg_file" "v$VERSION"
else
  git -C "$repo_root" tag -s -m "v$VERSION" "v$VERSION"
fi
echo "version bumped to $VERSION (build $build), tagged v$VERSION"
if [ "$has_headline" -eq 1 ]; then
  echo "release headline attached to tag v$VERSION"
fi
