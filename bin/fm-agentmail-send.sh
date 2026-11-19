#!/usr/bin/env bash
# fm-agentmail-send.sh - send one email from the home's AgentMail inbox, either
# new or as a reply in an existing thread.
#
# Usage:
#   fm-agentmail-send.sh --to <address> [--to <address>...] --subject <text>
#       (--text <text> | --text-file <file|->) [--html-file <file>]
#       [--allow-recipient <address>...]
#   fm-agentmail-send.sh --reply-to-message <message-id> --to <address>...
#       (--text <text> | --text-file <file|->) [--html-file <file>]
#       [--allow-recipient <address>...]
#   fm-agentmail-send.sh --repo <owner/name> ...   (instead of or besides --to)
#   fm-agentmail-send.sh --help
#
# Every recipient must be an owner address in config/agentmail.
# A recipient outside that allowlist is refused unless
# that exact address is named by --allow-recipient on this one invocation; the
# flag is never remembered. A reply names its recipients explicitly with --to
# and never uses reply-all, so the same check covers it. cc and bcc are not
# supported. A reply keeps its thread's subject, so --subject is refused with
# --reply-to-message.
#
# --repo <owner/name> adds the address that config/agentmail's
# route=<github owner>:<address> line maps that repository's owner to, so mail
# about ryannmicua/* and adventistasia/* repositories reaches the right owner
# address. A repository whose owner has no route is refused. The routed address
# still passes the allowlist check.
#
# Prints message_id=<id> and thread_id=<id> on success. Exit status 1 or 2
# means nothing was sent: a local check failed before the API call, or
# AgentMail refused it with a 4xx error message. Exit status 3 means the outcome
# is uncertain (no response, timeout, server error, or a reply without a message
# id) and the email may have been sent. The API key is read from
# config/agentmail.key and is never printed.
# Operator setup is owned by docs/configuration.md "AgentMail inbox".
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SCRIPT_DIR/fm-agentmail-send.sh"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-agentmail-lib.sh
. "$SCRIPT_DIR/fm-agentmail-lib.sh"

usage() {
  sed -n '2,/^set -u$/p' "$SELF" | sed '$d' | sed 's/^# \{0,1\}//'
}

die() {
  printf 'fm-agentmail-send: %s\n' "$1" >&2
  exit "${2:-1}"
}

TO=()
REPOS=()
EXTRA=()
SUBJECT=
TEXT=
HAVE_TEXT=0
HTML=
REPLY_TO=

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --to|--subject|--text|--text-file|--html-file|--reply-to-message|--allow-recipient|--repo)
      [ "$#" -ge 2 ] || die "$1 needs a value" 2
      ;;
  esac
  case "$1" in
    --to) fm_am_addr_ok "$2" || die "--to is not a plain email address" 2; TO+=("$(fm_am_lower "$2")"); shift 2 ;;
    --allow-recipient) fm_am_addr_ok "$2" || die "--allow-recipient is not a plain email address" 2; EXTRA+=("$(fm_am_lower "$2")"); shift 2 ;;
    --repo) REPOS+=("$2"); shift 2 ;;
    --subject) SUBJECT=$2; shift 2 ;;
    --text) TEXT=$2; HAVE_TEXT=1; shift 2 ;;
    --text-file)
      if [ "$2" = - ]; then TEXT=$(cat); else TEXT=$(cat -- "$2") || die "cannot read $2" 2; fi
      HAVE_TEXT=1; shift 2 ;;
    --html-file) HTML=$(cat -- "$2") || die "cannot read $2" 2; shift 2 ;;
    --reply-to-message) REPLY_TO=$2; shift 2 ;;
    *) usage >&2; die "unknown argument: $1" 2 ;;
  esac
done

[ "$HAVE_TEXT" -eq 1 ] && [ -n "$TEXT" ] || die "a non-empty --text or --text-file is required" 2
if [ -n "$REPLY_TO" ]; then
  [ -z "$SUBJECT" ] || die "--subject cannot be used with --reply-to-message; a reply keeps its thread's subject" 2
else
  [ -n "$SUBJECT" ] || die "--subject is required for a new email" 2
  case "$SUBJECT" in *$'\n'*|*$'\r'*) die "--subject must be one line" 2 ;; esac
fi

fm_am_load_config "$CONFIG" || die "$FM_AM_CONFIG_ERROR"

for repo in ${REPOS[@]+"${REPOS[@]}"}; do
  routed=$(fm_am_route_for "$repo") || die "no recipient route for repository $repo; add route=<github owner>:<address> to config/agentmail" 2
  TO+=("$routed")
done
[ "${#TO[@]}" -gt 0 ] || die "at least one --to or --repo is required" 2

for addr in "${TO[@]}"; do
  if fm_am_in_list "$addr" "${FM_AM_OWNERS[@]}"; then continue; fi
  if [ "${#EXTRA[@]}" -gt 0 ] && fm_am_in_list "$addr" "${EXTRA[@]}"; then continue; fi
  die "$addr is not on the allowlist in config/agentmail; pass --allow-recipient $addr only when the owner asked for this specific email"
done

to_json=$(printf '%s\n' "${TO[@]}" | jq -Rn '[inputs]')
inbox_path="/v0/inboxes/$(fm_am_urlenc "$FM_AM_INBOX")"
if [ -n "$REPLY_TO" ]; then
  body=$(jq -nc --argjson to "$to_json" --arg text "$TEXT" --arg html "$HTML" \
    '{to: $to, text: $text} + (if $html == "" then {} else {html: $html} end)')
  target="$inbox_path/messages/$(fm_am_urlenc "$REPLY_TO")/reply"
else
  body=$(jq -nc --argjson to "$to_json" --arg subject "$SUBJECT" --arg text "$TEXT" --arg html "$HTML" \
    '{to: $to, subject: $subject, text: $text} + (if $html == "" then {} else {html: $html} end)')
  target="$inbox_path/messages/send"
fi

if ! fm_am_api POST "$target" "$body" || [ "$FM_AM_STATUS" != 200 ]; then
  detail=$(jq -r '.message // empty' <<<"$FM_AM_BODY" 2>/dev/null | head -c 200)
  case "$FM_AM_STATUS" in
    4[0-9][0-9]) [ -z "$detail" ] || die "AgentMail refused the email (HTTP $FM_AM_STATUS): $detail" ;;
  esac
  die "AgentMail gave no definitive answer (HTTP $FM_AM_STATUS)${detail:+: $detail}; the email may have been sent" 3
fi
mid=$(jq -r '.message_id // empty' <<<"$FM_AM_BODY")
tid=$(jq -r '.thread_id // empty' <<<"$FM_AM_BODY")
[ -n "$mid" ] || die "AgentMail answered without a message id; the email may have been sent" 3
printf 'message_id=%s\nthread_id=%s\n' "$mid" "$tid"
