# shellcheck shell=bash
# shellcheck disable=SC2034 # FM_AM_CONFIG_ERROR is read by the scripts that source this library.
# AgentMail access shared by bin/fm-agentmail-check.sh (the inbound poll) and
# bin/fm-agentmail-send.sh (the outbound sender).
# Usage: . bin/fm-agentmail-lib.sh   (requires curl and jq)
#
# Operator setup is owned by docs/configuration.md "AgentMail inbox".
#
# Secret handling, owned here:
#   - The API key is read from a private key file on every call and never enters
#     any process argv: it reaches curl as a `header = "Authorization: ..."`
#     line of a --config document that the shell's printf builtin writes to
#     curl's stdin.
#   - A key is accepted only as one token of URL-safe characters, so it cannot
#     break out of that config line.
#   - Response bodies land in a private (0600) temporary file that is removed
#     before the call returns; callers receive the body in FM_AM_BODY.
#   - Nothing here prints or logs the key.
#
# FM_AGENTMAIL_API_URL overrides the API base (default
# https://api.agentmail.to) so tests can point the calls at a fake;
# FM_AGENTMAIL_API_TIMEOUT bounds each call in seconds (default 20).

# shellcheck source=bin/fm-gh-api-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-gh-api-lib.sh"

# Callers read these after each fm_am_api call.
# shellcheck disable=SC2034
FM_AM_STATUS=
# shellcheck disable=SC2034
FM_AM_BODY=

# Set by fm_am_load_config; callers read them.
# shellcheck disable=SC2034
FM_AM_INBOX=
FM_AM_KEY=
# shellcheck disable=SC2034
FM_AM_OWNERS=()
# shellcheck disable=SC2034
FM_AM_ROUTES=()
# shellcheck disable=SC2034
FM_AM_CONFIG_ERROR=

fm_am_lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# fm_am_addr_ok <address>: 0 for one plain mailbox address, with nothing that
# could add a second recipient or a header line.
fm_am_addr_ok() {
  case "$1" in
    ''|*[!A-Za-z0-9._%+@-]*) return 1 ;;
  esac
  case "$1" in
    *@*@*|@*|*@|*@.*|*@*..*|*@-*) return 1 ;;
    *@*.*) return 0 ;;
  esac
  return 1
}

# fm_am_from_addr <From value>: print the lowercase address of a single sender,
# `addr` or `Display Name <addr>`. Fails for a list of senders, a display name
# that itself contains an address, or anything that is not one plain address.
fm_am_from_addr() {
  local value=$1 addr display
  case "$value" in
    *'>')
      addr=${value##*<}
      display=${value%<*}
      case "$display" in *'<'*|*'>'*|*@*) return 1 ;; esac
      addr=${addr%>}
      ;;
    *) addr=$value ;;
  esac
  addr=${addr#"${addr%%[![:space:]]*}"}
  addr=${addr%"${addr##*[![:space:]]}"}
  fm_am_addr_ok "$addr" || return 1
  fm_am_lower "$addr"
}

fm_am_urlenc() {
  jq -rn --arg s "$1" '$s | @uri'
}

# fm_am_add_list <array-name> <comma-separated values>: append valid lowercase
# addresses; fail on the first invalid one.
fm_am_add_list() {
  local name=$1 raw=$2 item
  local -a parts
  IFS=',' read -r -a parts <<<"$raw"
  for item in "${parts[@]}"; do
    item=${item#"${item%%[![:space:]]*}"}
    item=${item%"${item##*[![:space:]]}"}
    [ -n "$item" ] || continue
    fm_am_addr_ok "$item" || return 1
    eval "$name+=(\"\$(fm_am_lower \"\$item\")\")"
  done
}

# fm_am_load_config <config-dir>: read config/agentmail and its key file.
# Sets FM_AM_INBOX, FM_AM_OWNERS, FM_AM_ROUTES
# and FM_AM_KEY, or fails with FM_AM_CONFIG_ERROR set.
fm_am_load_config() {
  local dir=$1 file line key value
  file="$dir/agentmail"
  FM_AM_INBOX='' FM_AM_KEY='' FM_AM_OWNERS=() FM_AM_ROUTES=() FM_AM_CONFIG_ERROR=''
  if ! [ -f "$file" ] || [ -L "$file" ]; then
    FM_AM_CONFIG_ERROR="config/agentmail is missing"
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    line=${line//$'\r'/}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    [ -n "$line" ] || continue
    case "$line" in
      *=*) key=${line%%=*}; value=${line#*=} ;;
      *) FM_AM_CONFIG_ERROR="config/agentmail has a line that is not key=value"; return 1 ;;
    esac
    case "$key" in
      inbox)
        fm_am_addr_ok "$value" || { FM_AM_CONFIG_ERROR="config/agentmail inbox is not an email address"; return 1; }
        FM_AM_INBOX=$(fm_am_lower "$value")
        ;;
      owner)
        fm_am_add_list FM_AM_OWNERS "$value" || { FM_AM_CONFIG_ERROR="config/agentmail owner is not an email address"; return 1; }
        ;;
      route)
        # route=<github owner>:<address> picks the recipient for that owner's repositories.
        case "${value%%:*}" in ''|*[!A-Za-z0-9-]*|-*) FM_AM_CONFIG_ERROR="config/agentmail route needs <github owner>:<address>"; return 1 ;; esac
        fm_am_addr_ok "${value#*:}" || { FM_AM_CONFIG_ERROR="config/agentmail route needs <github owner>:<address>"; return 1; }
        FM_AM_ROUTES+=("$(fm_am_lower "${value%%:*}"):$(fm_am_lower "${value#*:}")")
        ;;
      *) FM_AM_CONFIG_ERROR="config/agentmail has unknown key $key (accepted: inbox, owner, route)"; return 1 ;;
    esac
  done < "$file"
  [ -n "$FM_AM_INBOX" ] || { FM_AM_CONFIG_ERROR="config/agentmail needs inbox=<address>"; return 1; }
  [ "${#FM_AM_OWNERS[@]}" -gt 0 ] || { FM_AM_CONFIG_ERROR="config/agentmail needs owner=<address>"; return 1; }
  FM_AM_KEY=$(fm_gh_read_token_file "$dir/agentmail.key") || {
    FM_AM_CONFIG_ERROR="the AgentMail key file is missing, not owner-only (chmod 600), or not one token"
    return 1
  }
}

# fm_am_route_for <owner/repo>: print the address configured for that
# repository's owner, or fail when the slug is invalid or has no route.
fm_am_route_for() {
  local slug=$1 owner entry
  fm_gh_slug_ok "$slug" || return 1
  owner=$(fm_am_lower "${slug%%/*}")
  for entry in "${FM_AM_ROUTES[@]}"; do
    if [ "${entry%%:*}" = "$owner" ]; then printf '%s' "${entry#*:}"; return 0; fi
  done
  return 1
}

# fm_am_in_list <address> <list element>...: 0 when the address is listed.
fm_am_in_list() {
  local want=$1 item
  shift
  for item in "$@"; do
    [ "$item" != "$want" ] || return 0
  done
  return 1
}

# fm_am_api <method> <path> [json-body]
# One authenticated call using FM_AM_KEY. Sets FM_AM_STATUS (HTTP status, or
# 000 when no response arrived) and FM_AM_BODY. Returns 0 when a response
# arrived, whatever its status; 1 when the call could not be made.
fm_am_api() {
  local method=$1 target=$2 body=${3:-} base out status rc=0
  local -a args
  FM_AM_STATUS=000
  FM_AM_BODY=
  base=${FM_AGENTMAIL_API_URL:-https://api.agentmail.to}
  case "$target" in /*) ;; *) return 1 ;; esac
  fm_gh_credential_ok "$FM_AM_KEY" || return 1
  out=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-agentmail-api.XXXXXX") || return 1
  args=(-sS --config - -X "$method" -o "$out" -w '%{http_code}'
    --max-time "${FM_AGENTMAIL_API_TIMEOUT:-20}"
    -H 'Accept: application/json'
    -H 'User-Agent: firstmate')
  if [ -n "$body" ]; then
    args+=(-H 'Content-Type: application/json' --data-binary "$body")
  fi
  status=$(printf 'header = "Authorization: Bearer %s"\n' "$FM_AM_KEY" | curl "${args[@]}" "${base%/}$target" 2>/dev/null) || rc=$?
  # shellcheck disable=SC2034 # Read by callers.
  FM_AM_BODY=$(cat "$out" 2>/dev/null) || FM_AM_BODY=
  rm -f -- "$out"
  case "$status" in
    [0-9][0-9][0-9]) FM_AM_STATUS=$status ;;
    *) FM_AM_STATUS=000 ;;
  esac
  [ "$rc" -eq 0 ] && [ "$FM_AM_STATUS" != 000 ]
}
