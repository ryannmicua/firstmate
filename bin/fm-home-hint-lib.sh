#!/usr/bin/env bash
# fm-home-hint-lib.sh - the retry hint fm-send and fm-control print when they
# refuse to run without an explicit FM_HOME.
#
# The refusal itself stays: a steer or lifecycle action must never silently
# resolve against another home. The hint only names the home candidate the
# script would have defaulted to (the tracked code root, as sibling scripts
# resolve it) and prints the exact command with FM_HOME set to it, for the
# caller to confirm and run. Nothing is exported or inferred on the caller's
# behalf, and no hint is printed when the candidate has no state directory.
#
# Usage: fm_home_refusal_hint <script-path> [original args...]

fm_home_refusal_hint() {
  local script=$1 candidate
  shift
  candidate=${FM_ROOT_OVERRIDE:-${FM_ROOT:-}}
  [ -n "$candidate" ] && [ -d "$candidate/state" ] || return 0
  candidate=$(cd "$candidate" && pwd) || return 0
  printf 'hint: if %q is the intended home, retry with: FM_HOME=%q %q' \
    "$candidate" "$candidate" "$script" >&2
  [ "$#" -eq 0 ] || printf ' %q' "$@" >&2
  printf '\n' >&2
}
