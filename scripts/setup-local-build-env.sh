#!/usr/bin/env bash
# Set up the local environment needed to (re)build the zig-based GhosttyKit /
# zmx artifacts under Xcode 26.5 on Apple Silicon. SOURCE this, then run the
# zig build scripts:
#
#   source scripts/setup-local-build-env.sh
#   ./scripts/build-ghostty.sh      # rebuild GhosttyKit.xcframework
#   ./scripts/build-zmx.sh          # rebuild bundled zmx
#
# Then build the Swift app normally (this env is ONLY for the zig steps — the
# app's xcodebuild must use the full Xcode toolchain, NOT Command Line Tools):
#
#   env -u DEVELOPER_DIR make build-app
#
# WHY each piece is needed (full background in LOCAL_DEV.md):
#   - DEVELOPER_DIR=CommandLineTools: Xcode 26.5's macOS SDK ships system .tbd
#     files with only an arm64e slice (no plain arm64). zig 0.15.2's self-hosted
#     linker won't fall back arm64->arm64e, so linking the zig build runner fails
#     with "undefined symbol: _<libSystem symbol>". The CLT SDK still carries the
#     arm64 slice, so pointing zig at it via DEVELOPER_DIR fixes the link.
#   - /tmp/metalwrap on PATH: CLT has no `metal`/`metallib`/`xcodebuild`. These
#     thin wrappers redirect those tools back to Xcode (which has the installed
#     Metal Toolchain) so the shader + xcframework steps still work.
#   - proxy unset: zig's HTTP/git fetcher fails through the local 127.0.0.1 proxy
#     (400 / HttpConnectionClosing); direct connections work.
#
# One-time prerequisites this script does NOT do for you:
#   - Install the Metal Toolchain (needed by `metal`/`metallib`):
#       xcodebuild -downloadComponent MetalToolchain
#   - Prime the zmx ghostty git dependency into its zig cache (only if
#     .build/zmx/.zig-global-cache was wiped) — see LOCAL_DEV.md "zmx".

set -u

# This script exports env vars into the caller's shell, so it must be sourced.
# Running it directly would set them only in a throwaway subprocess — fail loudly.
# Detection is portable across bash and zsh and safe under `set -u`.
_sourced=1
if [ -n "${BASH_VERSION:-}" ]; then
  [ "${BASH_SOURCE[0]}" = "${0}" ] && _sourced=0
elif [ -n "${ZSH_VERSION:-}" ]; then
  case "${ZSH_EVAL_CONTEXT:-}" in *:file*) _sourced=1 ;; *) _sourced=0 ;; esac
fi
if [ "$_sourced" -eq 0 ]; then
  echo "error: source this script, e.g. 'source scripts/setup-local-build-env.sh'" >&2
  exit 1
fi
unset _sourced

XCODE_DIR="/Applications/Xcode.app/Contents/Developer"
CLT_DIR="/Library/Developer/CommandLineTools"
WRAP_DIR="/tmp/metalwrap"

mkdir -p "$WRAP_DIR"
for tool in metal metallib xcodebuild; do
  cat > "$WRAP_DIR/$tool" <<EOF
#!/bin/bash
# Redirect a CLT-context tool call back to the full Xcode toolchain.
exec env DEVELOPER_DIR="$XCODE_DIR" /usr/bin/$tool "\$@"
EOF
  chmod +x "$WRAP_DIR/$tool"
done

export DEVELOPER_DIR="$CLT_DIR"
export PATH="$WRAP_DIR:$PATH"
unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy ALL_PROXY all_proxy 2>/dev/null || true

echo "local zig build env ready:"
echo "  DEVELOPER_DIR=$DEVELOPER_DIR  (Command Line Tools SDK, has arm64 slice)"
echo "  PATH prefixed with $WRAP_DIR  (metal/metallib/xcodebuild -> Xcode)"
echo "  proxy vars cleared for direct zig fetches"
echo
echo "now run: ./scripts/build-ghostty.sh  and/or  ./scripts/build-zmx.sh"
echo "then build the app with the FULL toolchain: env -u DEVELOPER_DIR make build-app"
