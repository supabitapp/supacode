#!/usr/bin/env bash
# Launch an ISOLATED local dev build ("tty7 Dev") that runs alongside the
# installed/main tty7 without clobbering its terminals, sessions, or state.
#
# Isolation layers (see LOCAL_DEV.md for the why):
#   - bundle id      app.supabit.tty7.dev   (Project.swift, Debug config)
#   - zmx socket dir $ZMX_DIR_ISO                 (default /tmp/zmx-dev)
#   - app state dir  $TTY7_HOME_DIR           (default ~/.tty7-dev)
#   - clean env      strips inherited ZMX_*/TTY7_*/GHOSTTY_* so launching
#                    from inside another tty7 terminal can't leak a stale
#                    ZMX_SESSION into the new build's terminals.
#
# Usage:
#   ./scripts/run-dev.sh            # build must already exist (make build-app)
#   TTY7_HOME_DIR=~/.tty7-x ZMX_DIR_ISO=/tmp/zmx-x ./scripts/run-dev.sh
set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TTY7_HOME_DIR="${TTY7_HOME_DIR:-$HOME/.tty7-dev}"
ZMX_DIR_ISO="${ZMX_DIR_ISO:-/tmp/zmx-dev}"
mkdir -p "$TTY7_HOME_DIR" "$ZMX_DIR_ISO"

settings="$(xcodebuild -workspace tty7.xcworkspace -scheme tty7 \
  -configuration Debug -showBuildSettings -json 2>/dev/null)"
# Select the app target explicitly — `-showBuildSettings -json` returns one entry
# per target in an undefined order, so `.[0]` can bind to the wrong target.
build_dir="$(printf '%s' "$settings" | jq -r '.[] | select(.target == "tty7") | .buildSettings.BUILT_PRODUCTS_DIR' | head -n1)"
product="$(printf '%s' "$settings" | jq -r '.[] | select(.target == "tty7") | .buildSettings.FULL_PRODUCT_NAME' | head -n1)"
exec_name="$(printf '%s' "$settings" | jq -r '.[] | select(.target == "tty7") | .buildSettings.EXECUTABLE_NAME' | head -n1)"

if [ -z "$build_dir" ] || [ "$build_dir" = "null" ] \
  || [ -z "$product" ] || [ "$product" = "null" ] \
  || [ -z "$exec_name" ] || [ "$exec_name" = "null" ]; then
  echo "error: could not resolve Debug 'tty7' app build settings" >&2
  exit 1
fi
bin="$build_dir/$product/Contents/MacOS/$exec_name"

if [ ! -x "$bin" ]; then
  echo "error: app not built at $bin" >&2
  echo "       run 'make build-app' first." >&2
  exit 1
fi

# env -u scrubs anything leaked from a parent tty7/Ghostty terminal; the two
# remaining vars pin this build onto its own isolated socket + state dirs.
nohup env \
  -u ZMX_SESSION -u ZMX_SESSION_PREFIX -u ZMX_DIR \
  -u TTY7_REPO_ID -u TTY7_ROOT_PATH -u TTY7_SOCKET_PATH \
  -u TTY7_SURFACE_ID -u TTY7_TAB_ID -u TTY7_WORKTREE_ID -u TTY7_WORKTREE_PATH \
  -u GHOSTTY_BIN_DIR -u GHOSTTY_RESOURCES_DIR -u GHOSTTY_SHELL_FEATURES \
  TTY7_HOME="$TTY7_HOME_DIR" ZMX_DIR="$ZMX_DIR_ISO" \
  "$bin" >/tmp/tty7-dev.out 2>&1 &
disown

echo "launched tty7 Dev (pid $!)"
echo "  TTY7_HOME=$TTY7_HOME_DIR"
echo "  ZMX_DIR=$ZMX_DIR_ISO"
echo "  logs: /tmp/tty7-dev.out"
