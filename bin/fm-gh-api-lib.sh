# shellcheck shell=bash
# GitHub REST access shared by the two GitHub identities a home may configure:
# bin/fm-gh-identity.sh (the identity workers write as) and
# bin/fm-gh-bot-check.sh (the bot account that listens for the owner).
# Usage: . bin/fm-gh-api-lib.sh   (requires curl, jq, and, for App JWTs, openssl)
#
# Secret handling, owned here:
#   - A credential never enters any process argv. It reaches curl as a
#     `header = "Authorization: ..."` line of a --config document written to
#     curl's stdin by the shell's printf builtin.
#   - A credential is accepted only when it is one token of URL-safe
#     characters, so it cannot break out of that config line.
#   - Response bodies land in a private (0600) temporary file that is removed
#     before the call returns; callers receive the body in FM_GH_API_BODY.
#   - Nothing here logs, echoes, or writes a credential anywhere.
#
# Private files: a key or token file must be a regular file (not a symlink)
# owned by this user with no group or other permission bits, or it refuses.
#
# FM_GH_API_URL overrides the API base (default https://api.github.com) so
# tests can point the calls at a fake; FM_GH_API_TIMEOUT bounds each call in
# seconds (default 20).

# Callers read these after each fm_gh_api call.
# shellcheck disable=SC2034
FM_GH_API_STATUS=
# shellcheck disable=SC2034
FM_GH_API_BODY=

# fm_gh_api_base: the API base URL without a trailing slash.
fm_gh_api_base() {
  local base=${FM_GH_API_URL:-https://api.github.com}
  printf '%s' "${base%/}"
}

# fm_gh_private_file_ok <path>: 0 when <path> is a regular file owned by this
# user that only its owner can read.
fm_gh_private_file_ok() {
  local path=$1 mode
  [ -f "$path" ] && [ ! -L "$path" ] && [ -O "$path" ] && [ -r "$path" ] || return 1
  if [ "$(uname)" = Darwin ]; then
    mode=$(/usr/bin/stat -f %Lp "$path" 2>/dev/null) || return 1
  else
    mode=$(stat -c %a "$path" 2>/dev/null) || return 1
  fi
  case "$mode" in
    ?00|00) return 0 ;;
  esac
  return 1
}

# fm_gh_credential_ok <value>: 0 when <value> is one nonempty token of
# characters a GitHub token or JWT uses.
fm_gh_credential_ok() {
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# fm_gh_read_token_file <path>: print the single token a private token file
# holds (surrounding whitespace and one final newline tolerated). Prints
# nothing and fails when the file is not private or not one token.
fm_gh_read_token_file() {
  local path=$1 value
  fm_gh_private_file_ok "$path" || return 1
  value=$(tr -d ' \t\r\n' < "$path" 2>/dev/null) || return 1
  fm_gh_credential_ok "$value" || return 1
  printf '%s' "$value"
}

# fm_gh_slug_ok <owner/repo>: 0 for a plain GitHub owner/repository pair.
fm_gh_slug_ok() {
  local slug=$1 owner repo
  case "$slug" in
    */*/*|/*|*/|'') return 1 ;;
    */*) ;;
    *) return 1 ;;
  esac
  owner=${slug%%/*}
  repo=${slug#*/}
  case "$owner" in
    ''|-*|*[!A-Za-z0-9-]*) return 1 ;;
  esac
  case "$repo" in
    ''|.|..|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# fm_gh_slug_from_url <remote-url>: print owner/repo for a github.com remote
# in https, ssh, or scp form; fail for any other host.
fm_gh_slug_from_url() {
  local url=$1 path
  case "$url" in
    https://github.com/*) path=${url#https://github.com/} ;;
    https://*@github.com/*) path=${url#https://*@github.com/} ;;
    ssh://git@github.com/*) path=${url#ssh://git@github.com/} ;;
    git@github.com:*) path=${url#git@github.com:} ;;
    *) return 1 ;;
  esac
  path=${path%/}
  path=${path%.git}
  fm_gh_slug_ok "$path" || return 1
  printf '%s' "$path"
}

# fm_gh_api <method> <path-or-url> <scheme> <credential> [json-body]
# One authenticated REST call. <scheme> is Bearer or token; an empty
# <credential> sends no Authorization header. Sets FM_GH_API_STATUS (HTTP
# status, or 000 when no response arrived) and FM_GH_API_BODY. Returns 0 when
# a response arrived, whatever its status; 1 when the call could not be made.
fm_gh_api() {
  local method=$1 target=$2 scheme=$3 cred=$4 body=${5:-} url out status rc=0
  local -a args
  FM_GH_API_STATUS=000
  FM_GH_API_BODY=
  case "$target" in
    https://*|http://*) url=$target ;;
    /*) url="$(fm_gh_api_base)$target" ;;
    *) return 1 ;;
  esac
  if [ -n "$cred" ]; then
    fm_gh_credential_ok "$cred" || return 1
    case "$scheme" in Bearer|token) ;; *) return 1 ;; esac
  fi
  out=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-gh-api.XXXXXX") || return 1
  args=(-sS --config - -X "$method" -o "$out" -w '%{http_code}'
    --max-time "${FM_GH_API_TIMEOUT:-20}"
    -H 'Accept: application/vnd.github+json'
    -H 'X-GitHub-Api-Version: 2022-11-28'
    -H 'User-Agent: firstmate')
  if [ -n "$body" ]; then
    args+=(-H 'Content-Type: application/json' --data-binary "$body")
  fi
  if [ -n "$cred" ]; then
    status=$(printf 'header = "Authorization: %s %s"\n' "$scheme" "$cred" | curl "${args[@]}" "$url" 2>/dev/null) || rc=$?
  else
    status=$(: | curl "${args[@]}" "$url" 2>/dev/null) || rc=$?
  fi
  # shellcheck disable=SC2034 # Read by callers.
  FM_GH_API_BODY=$(cat "$out" 2>/dev/null) || FM_GH_API_BODY=
  rm -f -- "$out"
  case "$status" in
    [0-9][0-9][0-9]) FM_GH_API_STATUS=$status ;;
    *) FM_GH_API_STATUS=000 ;;
  esac
  [ "$rc" -eq 0 ] && [ "$FM_GH_API_STATUS" != 000 ]
}

fm_gh_b64url() {
  openssl base64 -A | tr '+/' '-_' | tr -d '='
}

# fm_gh_app_jwt <app-id> <private-key-file>: print a ten-minute RS256 App JWT
# (issued a minute in the past to tolerate clock drift, as GitHub advises).
fm_gh_app_jwt() {
  local app_id=$1 key=$2 now header payload sig
  case "$app_id" in ''|*[!0-9]*) return 1 ;; esac
  fm_gh_private_file_ok "$key" || return 1
  now=$(date +%s) || return 1
  header=$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | fm_gh_b64url) || return 1
  payload=$(printf '{"iat":%s,"exp":%s,"iss":"%s"}' "$((now - 60))" "$((now + 540))" "$app_id" | fm_gh_b64url) || return 1
  sig=$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -sign "$key" -binary 2>/dev/null | fm_gh_b64url) || return 1
  [ -n "$sig" ] || return 1
  printf '%s.%s.%s' "$header" "$payload" "$sig"
}
