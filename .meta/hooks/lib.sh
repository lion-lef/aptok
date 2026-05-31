# shellcheck shell=sh
# Shared helpers for Aptok spec-check hooks.
#
# This file is meant to be sourced, not executed directly. It provides:
#   - repo_root            : absolute path to the repository root
#   - log / warn / fail    : consistent, prefixed output helpers
#   - require_cmd          : assert an executable is available on PATH
#   - run_step             : run a labelled command, timing and reporting it
#
# All helpers are POSIX sh compatible so the hooks run anywhere /bin/sh exists.

# Resolve the repository root from this file's location (.meta/hooks/lib.sh).
hooks_lib_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# When sourced, $0 may be the caller; fall back to a known marker search.
if [ ! -f "$hooks_lib_dir/lib.sh" ]; then
  hooks_lib_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE:-$0}")" && pwd)
fi
repo_root=$(CDPATH= cd -- "$hooks_lib_dir/../.." && pwd)
export repo_root

# Colour output only when stdout is a terminal.
if [ -t 1 ]; then
  c_reset='\033[0m'; c_green='\033[32m'; c_yellow='\033[33m'; c_red='\033[31m'; c_blue='\033[34m'
else
  c_reset=''; c_green=''; c_yellow=''; c_red=''; c_blue=''
fi

log() {
  printf '%b==>%b %s\n' "$c_blue" "$c_reset" "$*"
}

ok() {
  printf '%b ok%b  %s\n' "$c_green" "$c_reset" "$*"
}

warn() {
  printf '%bwarn%b %s\n' "$c_yellow" "$c_reset" "$*" >&2
}

fail() {
  printf '%bFAIL%b %s\n' "$c_red" "$c_reset" "$*" >&2
}

# require_cmd <command> [hint]
# Returns 0 if the command exists, otherwise prints a hint and returns 1.
require_cmd() {
  cmd=$1
  hint=$2
  if command -v "$cmd" >/dev/null 2>&1; then
    return 0
  fi
  fail "required command not found: $cmd"
  [ -n "$hint" ] && warn "$hint"
  return 1
}

# run_step <label> <command...>
# Runs a command from the repo root, printing a header and final status.
run_step() {
  label=$1
  shift
  log "$label"
  if (cd "$repo_root" && "$@"); then
    ok "$label"
    return 0
  fi
  fail "$label"
  return 1
}
