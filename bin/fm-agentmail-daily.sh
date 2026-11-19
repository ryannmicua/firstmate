#!/usr/bin/env bash
# fm-agentmail-daily.sh - send the daily Quarterdeck product email.
# Usage: fm-agentmail-daily.sh --repo <owner/name> --html-file <file>
#        --text-file <file> [--subject <text>]
# Sends through fm-agentmail-send.sh using only the repository's owner route.
# state/agentmail-daily.sent-day holds "<local date> pending" while a send is
# in flight and "<local date> sent" after it succeeds. Any record for today
# refuses another send: a send whose outcome is uncertain (timeout, transport
# failure, lost response, server error, unrecordable success) or that was
# interrupted keeps the day consumed. Only a definitive refusal (AgentMail's
# 4xx with an error message, or a local check before any API call) clears the
# reservation for a retry. state/agentmail-daily.log records dates and
# send/refusal results without mail content or credentials.
# state/.agentmail-daily.lock, a symlink to the holder's pid, serializes
# invocations; a lock whose holder is no longer running is taken over.
# FM_AGENTMAIL_DAILY_DATE overrides the local YYYY-MM-DD date for testing.
set -u
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DAY=$(date +%F) || exit 1
REPO=
HTML=
TEXT=
SUBJECT='Quarterdeck daily product email'

log_result() {
  mkdir -p "$STATE" && printf '%s %s\n' "$DAY" "$1" >> "$STATE/agentmail-daily.log"
}

refuse() {
  log_result "refused $1" || exit 1
  printf 'fm-agentmail-daily: %s\n' "$1" >&2
  exit "${2:-1}"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    --repo|--html-file|--text-file|--subject)
      [ "$#" -ge 2 ] && [ -n "$2" ] || refuse 'option requires a value' 2
      case "$1" in
        --repo) [ -z "$REPO" ] || refuse 'only one repository is allowed' 2; REPO=$2 ;;
        --html-file) HTML=$2 ;;
        --text-file) TEXT=$2 ;;
        --subject) SUBJECT=$2 ;;
      esac
      shift 2 ;;
    *) refuse 'unknown argument' 2 ;;
  esac
done
[ -n "$REPO" ] && [ -f "$HTML" ] && [ -s "$HTML" ] && [ -f "$TEXT" ] && [ -s "$TEXT" ] || refuse 'repository and nonempty HTML and text files are required' 2
if [ -n "${FM_AGENTMAIL_DAILY_DATE:-}" ]; then
  [[ "$FM_AGENTMAIL_DAILY_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || refuse 'invalid test date' 2
  DAY=$FM_AGENTMAIL_DAILY_DATE
fi
mkdir -p "$STATE" || exit 1
LOCK="$STATE/.agentmail-daily.lock"
SENT="$STATE/agentmail-daily.sent-day"

lock_holder_live() {
  local pid
  pid=$(readlink "$LOCK" 2>/dev/null) || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null && ps -o args= -p "$pid" 2>/dev/null | grep -q 'fm-agentmail-daily\.sh'
}

write_record() {
  local tmp
  tmp=$(mktemp "$STATE/.agentmail-daily.sent-day.XXXXXX") || return 1
  if ! printf '%s %s\n' "$DAY" "$1" > "$tmp" || ! mv -f -- "$tmp" "$SENT"; then
    rm -f -- "$tmp"
    return 1
  fi
}

if ! ln -s "$$" "$LOCK" 2>/dev/null; then
  STALE=$(readlink "$LOCK" 2>/dev/null) || refuse 'daily send is locked'
  lock_holder_live && refuse 'daily send is locked'
  [ "$(readlink "$LOCK" 2>/dev/null)" = "$STALE" ] && rm -f -- "$LOCK"
  ln -s "$$" "$LOCK" 2>/dev/null || refuse 'daily send is locked'
fi
trap '[ "$(readlink "$LOCK" 2>/dev/null)" != "$$" ] || rm -f -- "$LOCK"' EXIT
if [ -e "$SENT" ]; then
  LAST_DAY=
  read -r LAST_DAY _ < "$SENT" || [ -n "$LAST_DAY" ] || refuse 'cannot read sent day'
  [ "$LAST_DAY" != "$DAY" ] || refuse 'already sent today'
fi
log_result attempt || exit 1
write_record pending || refuse 'cannot reserve the day'
rc=0
FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-agentmail-send.sh" --repo "$REPO" --html-file "$HTML" --text-file "$TEXT" --subject "$SUBJECT" >/dev/null 2>&1 || rc=$?
case "$rc" in
  0) ;;
  1|2) rm -f -- "$SENT" || refuse 'send refused; day stays reserved'
     refuse 'send failed' ;;
  *) refuse 'send outcome uncertain; day consumed' ;;
esac
write_record sent || refuse 'sent but could not record day'
log_result sent || exit 1
printf 'sent: %s\n' "$DAY"
