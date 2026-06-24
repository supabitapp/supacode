#!/usr/bin/env bash
# Verifies the build prerequisites on macOS 26.4+ and prints the fix for each
# failure, instead of a 200-line Zig linker dump.
#
# Usage: scripts/doctor.sh [--quiet]   (--quiet prints only failures). Exit 1 on any.
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"

quiet=0
[ "${1:-}" = "--quiet" ] && quiet=1

failures=0

# Fall back to the absolute path; mise is often missing from non-login shells.
mise_bin="mise"
command -v mise >/dev/null 2>&1 || mise_bin="${HOME}/.local/bin/mise"
has_mise() { command -v "${mise_bin}" >/dev/null 2>&1 || [ -x "${mise_bin}" ]; }

pass() { [ "${quiet}" -eq 1 ] || printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() {
  failures=$((failures + 1))
  printf '  \033[31m✗\033[0m %s\n' "$1" >&2
  printf '      fix: %s\n' "$2" >&2
}

[ "${quiet}" -eq 1 ] || printf '\033[1msupacode doctor\033[0m\n'

# 1. mise on PATH
if command -v mise >/dev/null 2>&1; then
  pass "mise on PATH"
elif [ -x "${HOME}/.local/bin/mise" ]; then
  fail "mise installed but not on PATH (~/.local/bin/mise)" \
    "echo 'eval \"\$(~/.local/bin/mise activate zsh)\"' >> ~/.zshrc && exec zsh"
else
  fail "mise not installed" "curl https://mise.run | sh"
fi

# 2. submodules
missing_sub=()
[ -f "${repo_root}/ThirdParty/ghostty/build.zig" ] || missing_sub+=("ThirdParty/ghostty")
[ -f "${repo_root}/ThirdParty/zmx/build.zig" ] || missing_sub+=("ThirdParty/zmx")
[ -f "${repo_root}/Resources/git-wt/wt" ] || missing_sub+=("Resources/git-wt")
if [ "${#missing_sub[@]}" -eq 0 ]; then
  pass "git submodules initialized"
else
  fail "git submodules missing: ${missing_sub[*]}" "git submodule update --init --recursive"
fi

# 3. Zig-linkable Xcode
developer_dir="$("${script_dir}/select-developer-dir.sh" 2>/dev/null)" || developer_dir=""
if [ -n "${developer_dir}" ]; then
  sdk="$(DEVELOPER_DIR="${developer_dir}" xcrun --sdk macosx --show-sdk-path 2>/dev/null)"
  pass "Zig-linkable Xcode: ${developer_dir} ($(basename "${sdk:-unknown}"))"
else
  fail "no Zig-linkable Xcode: macOS 26.4+ SDK dropped arm64-macos (ziglang/zig#31658)" \
    "install Xcode 26.3 (ships the macOS 26.2 SDK): https://developer.apple.com/download/all/?q=Xcode%2026.3"
fi

# 4 and 5 need an Xcode to point at.
if [ -n "${developer_dir}" ]; then
  # 4. license / first launch
  if DEVELOPER_DIR="${developer_dir}" xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
    pass "Xcode license accepted & first launch complete"
  else
    fail "Xcode needs license / first launch (DEVELOPER_DIR alone won't work until done)" \
      "sudo DEVELOPER_DIR=${developer_dir} xcodebuild -license accept && sudo DEVELOPER_DIR=${developer_dir} xcodebuild -runFirstLaunch"
  fi

  # 5. Metal Toolchain
  if DEVELOPER_DIR="${developer_dir}" xcrun metal --version >/dev/null 2>&1; then
    pass "Metal Toolchain installed"
  else
    fail "Metal Toolchain missing (ghostty compiles Metal shaders)" \
      "sudo DEVELOPER_DIR=${developer_dir} xcodebuild -downloadComponent MetalToolchain"
  fi
fi

# 6. pinned mise tools
if has_mise; then
  missing_tools=()
  for tool in zig tuist swiftlint xcbeautify swift-format; do
    "${mise_bin}" which "${tool}" >/dev/null 2>&1 || missing_tools+=("${tool}")
  done
  if [ "${#missing_tools[@]}" -eq 0 ]; then
    pass "mise tools installed (zig, tuist, swiftlint, xcbeautify, swift-format)"
  else
    fail "mise tools missing: ${missing_tools[*]}" "mise install"
  fi
fi

if [ "${failures}" -gt 0 ]; then
  printf '\n\033[31m%d check(s) failed.\033[0m Fix the above, then re-run `make doctor`.\n' "${failures}" >&2
  exit 1
fi
[ "${quiet}" -eq 1 ] || printf '\n\033[32mAll checks passed.\033[0m\n'
exit 0
