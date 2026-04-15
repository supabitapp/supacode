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
