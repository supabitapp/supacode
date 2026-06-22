#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="${SRCROOT:-$(cd "${script_dir}/.." && pwd)}"

app_path="${SUPACODE_APP_PATH:-${repo_root}/build/supacode/Build/Products/Debug/supacode.app}"
cli_path="${SUPACODE_CLI:-${app_path}/Contents/Resources/bin/supacode}"
zmx_path="${ZMX:-${app_path}/Contents/Resources/zmx/zmx}"
target_repo="${repo_root}"
worktree_id=""
created_tab_id=""
surface_id=""
session_id=""
timeout_seconds="${SUPACODE_SMOKE_TIMEOUT:-12}"
settle_seconds="${SUPACODE_SMOKE_SETTLE_SECONDS:-2}"
keep_tab=false

usage() {
  cat <<'EOF'
Usage: scripts/smoke-zmx-crash-recovery.sh [--repo PATH] [--worktree ID] [--timeout SECONDS] [--settle SECONDS] [--keep-tab]

Creates a zmx-backed Supacode tab, forcibly detaches the zmx client process,
and verifies the same tab/surface/session survives. This exercises the regression
where an unexpected zmx client exit used to close the Supacode tab and kill the session.

Options:
  --repo PATH       Repo path to open before selecting the focused worktree. Defaults to this repo.
  --worktree ID     Existing worktree ID to target. Skips $SUPACODE_WORKTREE_ID and `supacode repo open`.
  --timeout SECONDS Polling timeout for each async app observation. Defaults to 12.
  --settle SECONDS  Require the recovered tab to stay alive for this long before PASS. Defaults to 2.
  --keep-tab        Leave the created tab open after the smoke test.

Environment overrides:
  SUPACODE_WORKTREE_ID Existing worktree ID to target when --worktree is omitted.
  SUPACODE_APP_PATH Path to the .app under test.
  SUPACODE_CLI      Path to the supacode CLI under test.
  SUPACODE_SMOKE_SETTLE_SECONDS Stable-survival duration after detach. Defaults to 2.
  ZMX               Path to the zmx binary used for `zmx ls`.
EOF
}

fail() {
  echo "error: $*" >&2
  exit 1
}

note() {
  printf '==> %s\n' "$*"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)
      [ "$#" -ge 2 ] || fail "--repo requires a path"
      target_repo="$2"
      shift 2
      ;;
    --worktree)
      [ "$#" -ge 2 ] || fail "--worktree requires an ID"
      worktree_id="$2"
      shift 2
      ;;
    --timeout)
      [ "$#" -ge 2 ] || fail "--timeout requires a number of seconds"
      timeout_seconds="$2"
      shift 2
      ;;
    --settle)
      [ "$#" -ge 2 ] || fail "--settle requires a number of seconds"
      settle_seconds="$2"
      shift 2
      ;;
    --keep-tab)
      keep_tab=true
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      target_repo="$1"
      shift
      ;;
  esac
done

case "${timeout_seconds}" in
  '' | *[!0-9]*)
    fail "--timeout must be a positive integer"
    ;;
esac

[ "${timeout_seconds}" -gt 0 ] || fail "--timeout must be greater than zero"
case "${settle_seconds}" in
  '' | *[!0-9]*)
    fail "--settle must be a non-negative integer"
    ;;
esac

[ -x "${cli_path}" ] || fail "missing executable CLI at ${cli_path}. Run: make build-app"
[ -x "${zmx_path}" ] || fail "missing executable zmx at ${zmx_path}. Run: make build-app"

target_repo="$(cd "${target_repo}" && pwd)"

normalize_list_lines() {
  awk '
    {
      escape = sprintf("%c", 27)
      gsub(escape "\\[[0-9;]*[[:alpha:]]", "")
      sub(/^[*] /, "")
      if (NF) {
        print
      }
    }
  '
}

first_list_id() {
  normalize_list_lines | awk 'NF { print; exit }'
}

list_ids() {
  normalize_list_lines
}

cleanup() {
  status=$?
  if [ "${keep_tab}" = false ] && [ -n "${created_tab_id}" ] && [ -n "${worktree_id}" ]; then
    if [ "${status}" -eq 0 ]; then
      note "Closing smoke-test tab ${created_tab_id}; pass --keep-tab to inspect it manually."
    fi
    "${cli_path}" tab close --worktree "${worktree_id}" --tab "${created_tab_id}" >/dev/null 2>&1 || true
  fi
  exit "${status}"
}
trap cleanup EXIT

wait_for() {
  description="$1"
  shift

  deadline=$(($(date +%s) + timeout_seconds))
  while true; do
    if "$@"; then
      return 0
    fi
    if [ "$(date +%s)" -ge "${deadline}" ]; then
      fail "timed out waiting for ${description}"
    fi
    sleep 0.2
  done
}

run_dispatch_allow_timeout() {
  local description output status
  description="$1"
  shift

  set +e
  output="$("$@" 2>&1)"
  status=$?
  set -e

  if [ "${status}" -eq 0 ]; then
    return 0
  fi

  if printf '%s\n' "${output}" | grep -F -q "Timed out waiting for response from Supacode."; then
    note "${description} did not answer within the CLI socket timeout; continuing to poll app state."
    return 0
  fi

  printf '%s\n' "${output}" >&2
  return "${status}"
}

capture_socket_count() {
  socket_output="$("${cli_path}" socket 2>/dev/null)" || return 1
  socket_count="$(printf '%s\n' "${socket_output}" | awk 'NF { count++ } END { print count + 0 }')"
  [ "${socket_count}" -gt 0 ]
}

capture_env_worktree() {
  [ -n "${SUPACODE_WORKTREE_ID:-}" ] || return 1
  worktree_id="${SUPACODE_WORKTREE_ID}"
  "${cli_path}" tab list --worktree "${worktree_id}" >/dev/null 2>&1
}

capture_focused_worktree() {
  output="$("${cli_path}" worktree list --focused 2>/dev/null)" || return 1
  worktree_id="$(printf '%s\n' "${output}" | first_list_id)"
  [ -n "${worktree_id}" ]
  "${cli_path}" tab list --worktree "${worktree_id}" >/dev/null 2>&1
}

tab_exists() {
  output="$("${cli_path}" tab list --worktree "${worktree_id}" 2>/dev/null)" || return 1
  printf '%s\n' "${output}" | list_ids | grep -F -q "${created_tab_id}"
}

session_exists() {
  "${zmx_path}" ls 2>/dev/null | grep -F -q "${session_id}"
}

capture_session_clients() {
  session_clients="$(
    "${zmx_path}" ls 2>/dev/null | awk -v session="${session_id}" '
      index($0, "name=" session) {
        for (i = 1; i <= NF; i++) {
          if ($i ~ /^clients=/) {
            sub(/^clients=/, "", $i)
            print $i
            exit
          }
        }
      }
    '
  )"
  case "${session_clients}" in
    '' | *[!0-9]*)
      return 1
      ;;
  esac
  [ "${session_clients}" -gt 0 ]
}

surface_still_exists() {
  output="$("${cli_path}" surface list --worktree "${worktree_id}" --tab "${created_tab_id}" 2>/dev/null)" || return 1
  printf '%s\n' "${output}" | first_list_id | grep -F -q "${surface_id}"
}

recovered_state_exists() {
  tab_exists
  surface_still_exists
  session_exists
  capture_session_clients
}

recovered_state_stays_alive() {
  deadline=$(($(date +%s) + settle_seconds))
  while [ "$(date +%s)" -lt "${deadline}" ]; do
    recovered_state_exists || return 1
    sleep 0.2
  done
}

detach_session_clients() {
  ZMX_SESSION="${session_id}" "${zmx_path}" detach >/dev/null
}

note "Using app: ${app_path}"
note "Using CLI: ${cli_path}"
note "Using zmx: ${zmx_path}"

if ! capture_socket_count; then
  note "No Supacode socket found; launching debug app by path."
  /usr/bin/open "${app_path}"
  wait_for "Supacode socket" capture_socket_count
fi

if [ "${socket_count}" -gt 1 ] && [ -z "${SUPACODE_SOCKET_PATH:-}" ]; then
  fail "multiple Supacode sockets found. Run from the target Supacode terminal or set SUPACODE_SOCKET_PATH."
fi

if [ -z "${worktree_id}" ]; then
  if capture_env_worktree; then
    note "Using SUPACODE_WORKTREE_ID: ${worktree_id}"
  else
    note "Opening repo: ${target_repo}"
    run_dispatch_allow_timeout "repo open" "${cli_path}" repo open "${target_repo}"
    wait_for "focused worktree after repo open" capture_focused_worktree
  fi
else
  note "Using supplied worktree: ${worktree_id}"
fi

created_tab_id="$(uuidgen)"
note "Creating tab ${created_tab_id} in worktree ${worktree_id}"
run_dispatch_allow_timeout "tab new" "${cli_path}" tab new --worktree "${worktree_id}" --id "${created_tab_id}"
wait_for "created tab ${created_tab_id}" tab_exists

surface_id="${created_tab_id}"
session_id="supa-$(printf '%s' "${surface_id}" | tr '[:upper:]' '[:lower:]')"
note "Surface: ${surface_id}"
note "Expected zmx session: ${session_id}"
wait_for "zmx session ${session_id}" session_exists
wait_for "zmx attached client for ${session_id}" capture_session_clients

note "Detaching zmx client for ${session_id}"
# This intentionally detaches only the client. Do not replace with `zmx kill`,
# which removes the backing session and should still close the surface.
detach_session_clients

wait_for "surface ${surface_id} to survive forced zmx attach exit" surface_still_exists
wait_for "zmx session ${session_id} to remain alive" session_exists
wait_for "reattached zmx client for ${session_id}" capture_session_clients
if [ "${settle_seconds}" -gt 0 ]; then
  note "Verifying recovered tab stays alive for ${settle_seconds}s"
  wait_for "recovered tab to stay alive for ${settle_seconds}s" recovered_state_stays_alive
fi

note "PASS: surface ${surface_id} and session ${session_id} survived the forced zmx client detach."
if [ "${keep_tab}" = true ]; then
  note "Left tab ${created_tab_id} open because --keep-tab was supplied."
fi
