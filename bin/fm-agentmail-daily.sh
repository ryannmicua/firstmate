#!/usr/bin/env bash
# fm-agentmail-daily.sh - send the daily Quarterdeck product email.
# Usage: fm-agentmail-daily.sh --repo <owner/name> --html-file <file>
#        --text-file <file> [--subject <text>]
# Sends through fm-agentmail-send.sh using only the repository's owner route.
# state/agentmail-daily/<local date> is created exclusively before sending, so
# only one invocation can reserve a date; it holds "pending" while the send is
# in flight and "sent" after it succeeds. An existing record for today refuses
# another send: a send whose outcome is uncertain (timeout, transport failure,
# lost response, server error, unrecordable success) or that was interrupted
# keeps the day consumed. Only a definitive refusal (AgentMail's 4xx with an
# error message, or a local check before any API call) removes the record so
# a retry may send.
# state/agentmail-daily.log records dates and send/refusal results without
# mail content or credentials.
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
DAYS="$STATE/agentmail-daily"
RECORD="$DAYS/$DAY"
mkdir -p "$DAYS" || exit 1
[ ! -e "$RECORD" ] || refuse 'already sent today'
log_result attempt || exit 1
if ! (set -o noclobber; printf 'pending\n' > "$RECORD") 2>/dev/null; then
  [ ! -e "$RECORD" ] || refuse 'already sent today'
  refuse 'cannot reserve the day'
fi
rc=0
FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-agentmail-send.sh" --repo "$REPO" --html-file "$HTML" --text-file "$TEXT" --subject "$SUBJECT" >/dev/null 2>&1 || rc=$?
case "$rc" in
  0) ;;
  1|2) rm -f -- "$RECORD" || refuse 'send refused; day stays reserved'
     refuse 'send failed' ;;
  *) refuse 'send outcome uncertain; day consumed' ;;
esac
printf 'sent\n' > "$RECORD" || refuse 'sent but could not record day'
log_result sent || exit 1
printf 'sent: %s\n' "$DAY"
