#!/usr/bin/env bash
# fm-gh-identity.sh - the optional GitHub identity a home's workers write as.
#
# Usage:
#   fm-gh-identity.sh status <owner/repo>
#       Report whether the configured identity can write to <owner/repo> and
#       the commit identity workers would use. Never prints a token.
#   fm-gh-identity.sh slug-of <worktree>
#       Print owner/repo for <worktree>'s configured github.com origin URL;
#       exit 3 when the origin is missing or not on github.com.
#   fm-gh-identity.sh check-remotes <worktree>
#       Refuse origin URLs with embedded credentials, including Git rewrites.
#   fm-gh-identity.sh prepare-worker <dir> <owner/repo>
#       Spawn-time step (bin/fm-spawn.sh). Check the identity can write to
#       <owner/repo>, resolve its commit identity, and write <dir> (profile
#       plus a `gh` wrapper). Exit 0 when prepared, 3 when the identity cannot
#       write to that repository, 1 on any other failure.
#   fm-gh-identity.sh env-file <dir> <out-file>
#       Pane-time step. Write <out-file> as one export statement that puts the
#       `gh` wrapper first on PATH, points gh at an empty config directory,
#       sets the commit identity, and appends git credential and URL entries
#       after the GIT_CONFIG_COUNT the pane inherited, the same way
#       bin/fm-git-strip-ai-trailers.sh env-file appends core.hooksPath.
#   fm-gh-identity.sh git-credential <dir> <get|store|erase>
#       Git credential helper (git appends the operation). `get` answers
#       github.com requests with the identity's token for the requested
#       repository; store and erase are no-ops.
#   fm-gh-identity.sh gh <dir> [gh-args...]
#       Run the real gh with GH_TOKEN set to the identity's token for the
#       worker's repository. The <dir>/bin/gh wrapper calls this.
#   fm-gh-identity.sh --help
#
# Configuration (local, gitignored; docs/configuration.md "GitHub identities"
# owns the operator setup). config/github-identity holds key=value lines
# (# comments allowed) and selects one kind:
#   kind=token   a user account, such as a machine user, writes. Keys:
#                token_file=<absolute path> (optional; default
#                config/github-identity.token), an owner-only file holding
#                that account's token. It is read on every use, so replacing
#                the file rotates the token. Commits use the account's login
#                and its users.noreply.github.com address.
#   kind=app     a GitHub App writes. Keys: app_id=<number> (required) and
#                private_key=<absolute path> (optional; default
#                config/github-identity.pem), an owner-only key file. Tokens
#                are minted per repository through that repository's own
#                installation (GET /repos/<owner>/<repo>/installation), so one
#                App installed on several accounts or organizations needs no
#                installation id; each token is scoped to that one repository,
#                cached owner-only under state/gh-identity/tokens, and minted
#                again when less than ten minutes remain, so a long-running
#                worker keeps working past the one-hour token lifetime.
#                Commits use the App's <slug>[bot] user.
# With no config/github-identity the home has no worker identity and nothing
# here runs.
#
# Exit codes: 0 success, 1 failure, 2 usage, 3 cannot write there or not GitHub.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SELF="$SCRIPT_DIR/fm-gh-identity.sh"

# shellcheck source=bin/fm-gh-api-lib.sh
. "$SCRIPT_DIR/fm-gh-api-lib.sh"

usage() {
  sed -n '2,/^set -u$/p' "$SELF" | sed '$d' | sed 's/^# \{0,1\}//'
}

die() {
  printf 'fm-gh-identity: %s\n' "$*" >&2
  exit 1
}

# set_home <home>: select the operational home whose config and state are used.
set_home() {
  FM_HOME=$1
  CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
  STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
  CACHE="$STATE/gh-identity"
}
set_home "${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

KIND=
APP_ID=
APP_KEY=
TOKEN_FILE=

# load_config: read config/github-identity, refusing an unknown kind or key,
# a malformed value, or a secret file that is not owner-only.
load_config() {
  local file="$CONFIG/github-identity" line key value
  KIND=
  APP_ID=
  APP_KEY="$CONFIG/github-identity.pem"
  TOKEN_FILE="$CONFIG/github-identity.token"
  [ -f "$file" ] && [ ! -L "$file" ] || { printf 'fm-gh-identity: %s is missing or not a regular file\n' "$file" >&2; return 1; }
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    line=${line//$'\r'/}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    [ -n "$line" ] || continue
    case "$line" in
      *=*) key=${line%%=*}; value=${line#*=} ;;
      *) printf 'fm-gh-identity: %s: expected key=value, got a bare line\n' "$file" >&2; return 1 ;;
    esac
    case "$key" in
      kind) KIND=$value ;;
      app_id) APP_ID=$value ;;
      private_key) APP_KEY=$value ;;
      token_file) TOKEN_FILE=$value ;;
      *) printf 'fm-gh-identity: %s: unknown key %s (accepted: kind, token_file, app_id, private_key)\n' "$file" "$key" >&2; return 1 ;;
    esac
  done < "$file"
  case "$KIND" in
    token)
      case "$TOKEN_FILE" in
        /*) ;;
        *) printf 'fm-gh-identity: %s: token_file must be an absolute path\n' "$file" >&2; return 1 ;;
      esac
      fm_gh_read_token_file "$TOKEN_FILE" >/dev/null || {
        printf 'fm-gh-identity: the token file %s is missing, a symlink, not yours, readable by others (chmod 600 it), or not one token\n' "$TOKEN_FILE" >&2
        return 1
      }
      ;;
    app)
      case "$APP_ID" in
        ''|*[!0-9]*) printf 'fm-gh-identity: %s: app_id must be the numeric App ID\n' "$file" >&2; return 1 ;;
      esac
      case "$APP_KEY" in
        /*) ;;
        *) printf 'fm-gh-identity: %s: private_key must be an absolute path\n' "$file" >&2; return 1 ;;
      esac
      fm_gh_private_file_ok "$APP_KEY" || {
        printf 'fm-gh-identity: the App private key %s is missing, a symlink, not yours, or readable by others (chmod 600 it)\n' "$APP_KEY" >&2
        return 1
      }
      ;;
    *) printf 'fm-gh-identity: %s: kind must be token or app\n' "$file" >&2; return 1 ;;
  esac
}

cache_dir() {
  local d
  for d in "$CACHE" "$CACHE/tokens" "$CACHE/installations"; do
    if [ ! -d "$d" ]; then
      (umask 077 && mkdir -p "$d") || return 1
    fi
    [ ! -L "$d" ] && [ -O "$d" ] || return 1
  done
}

# write_private <path> <content>: atomic owner-only write.
write_private() {
  local path=$1 content=$2 tmp
  tmp=$(umask 077; mktemp "$path.XXXXXX") || return 1
  if ! printf '%s\n' "$content" > "$tmp" || ! mv -f -- "$tmp" "$path"; then
    rm -f -- "$tmp"
    return 1
  fi
}

app_jwt() {
  fm_gh_app_jwt "$APP_ID" "$APP_KEY" || { printf 'fm-gh-identity: could not sign an App token with %s\n' "$APP_KEY" >&2; return 1; }
}

slug_key() {
  printf '%s' "${1/\//__}"
}

# installation_id <slug> [fresh]: print the installation id for <slug>.
# Returns 3 when GitHub reports the App is not installed for it.
installation_id() {
  local slug=$1 fresh=${2:-0} file jwt id
  file="$CACHE/installations/$APP_ID-$(slug_key "$slug")"
  if [ "$fresh" = 0 ] && [ -f "$file" ]; then
    id=$(cat "$file" 2>/dev/null)
    case "$id" in ''|*[!0-9]*) ;; *) printf '%s' "$id"; return 0 ;; esac
  fi
  jwt=$(app_jwt) || return 1
  fm_gh_api GET "/repos/$slug/installation" Bearer "$jwt" || {
    printf 'fm-gh-identity: could not reach GitHub to look up the App installation for %s\n' "$slug" >&2
    return 1
  }
  case "$FM_GH_API_STATUS" in
    200) ;;
    404) rm -f -- "$file"; return 3 ;;
    *) printf 'fm-gh-identity: GitHub answered %s looking up the App installation for %s\n' "$FM_GH_API_STATUS" "$slug" >&2; return 1 ;;
  esac
  if ! jq -e '.permissions.contents == "write"' <<<"$FM_GH_API_BODY" >/dev/null 2>&1; then
    rm -f -- "$file"
    return 3
  fi
  id=$(printf '%s' "$FM_GH_API_BODY" | jq -r '.id // empty' 2>/dev/null)
  case "$id" in ''|*[!0-9]*) printf 'fm-gh-identity: unexpected installation lookup answer for %s\n' "$slug" >&2; return 1 ;; esac
  write_private "$file" "$id" || true
  printf '%s' "$id"
}

# mint_token <slug>: print an installation token scoped to <slug>, reusing a
# cached one with more than ten minutes left.
mint_token() {
  local slug=$1 id file now expires token jwt repo body attempt rc
  now=$(date +%s)
  file="$CACHE/tokens/$APP_ID-$(slug_key "$slug")"
  if fm_gh_private_file_ok "$file"; then
    expires=$(sed -n 's/^expires=//p' "$file" 2>/dev/null)
    token=$(sed -n 's/^token=//p' "$file" 2>/dev/null)
    case "$expires" in
      ''|*[!0-9]*) ;;
      *)
        if [ "$((expires - now))" -gt 600 ] && fm_gh_credential_ok "$token"; then
          printf '%s' "$token"
          return 0
        fi
        ;;
    esac
  fi
  repo=${slug#*/}
  body=$(jq -cn --arg r "$repo" '{repositories: [$r]}') || return 1
  for attempt in 0 1; do
    rc=0
    id=$(installation_id "$slug" "$attempt") || rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    jwt=$(app_jwt) || return 1
    fm_gh_api POST "/app/installations/$id/access_tokens" Bearer "$jwt" "$body" || {
      printf 'fm-gh-identity: could not reach GitHub to mint a token for %s\n' "$slug" >&2
      return 1
    }
    case "$FM_GH_API_STATUS" in
      201) break ;;
      404|422) [ "$attempt" = 0 ] && continue
        printf 'fm-gh-identity: the App installation does not cover %s (GitHub answered %s)\n' "$slug" "$FM_GH_API_STATUS" >&2
        return 3 ;;
      *) printf 'fm-gh-identity: GitHub answered %s minting a token for %s\n' "$FM_GH_API_STATUS" "$slug" >&2; return 1 ;;
    esac
  done
  token=$(printf '%s' "$FM_GH_API_BODY" | jq -r '.token // empty' 2>/dev/null)
  expires=$(printf '%s' "$FM_GH_API_BODY" | jq -r '.expires_at // empty | fromdateiso8601' 2>/dev/null)
  FM_GH_API_BODY=
  fm_gh_credential_ok "$token" || { printf 'fm-gh-identity: unexpected token answer for %s\n' "$slug" >&2; return 1; }
  case "$expires" in ''|*[!0-9]*) expires=$((now + 3000)) ;; esac
  write_private "$file" "expires=$expires"$'\n'"token=$token" || true
  printf '%s' "$token"
}

# app_identity: print "<name>\t<email>" for the App's bot user, cached per App id.
app_identity() {
  local file="$CACHE/identity" cached_app name email jwt slug uid
  if [ -f "$file" ] && [ ! -L "$file" ]; then
    cached_app=$(sed -n 's/^app_id=//p' "$file")
    name=$(sed -n 's/^name=//p' "$file")
    email=$(sed -n 's/^email=//p' "$file")
    if [ "$cached_app" = "$APP_ID" ] && [ -n "$name" ] && [ -n "$email" ]; then
      printf '%s\t%s' "$name" "$email"
      return 0
    fi
  fi
  jwt=$(app_jwt) || return 1
  fm_gh_api GET /app Bearer "$jwt" || { printf 'fm-gh-identity: could not reach GitHub to read the App\n' >&2; return 1; }
  [ "$FM_GH_API_STATUS" = 200 ] || { printf 'fm-gh-identity: GitHub answered %s reading App %s; check app_id and the private key\n' "$FM_GH_API_STATUS" "$APP_ID" >&2; return 1; }
  slug=$(printf '%s' "$FM_GH_API_BODY" | jq -r '.slug // empty' 2>/dev/null)
  case "$slug" in ''|*[!A-Za-z0-9-]*) printf 'fm-gh-identity: unexpected App answer\n' >&2; return 1 ;; esac
  fm_gh_api GET "/users/$slug%5Bbot%5D" Bearer "$jwt" || { printf 'fm-gh-identity: could not reach GitHub to read the App bot user\n' >&2; return 1; }
  if [ "$FM_GH_API_STATUS" != 200 ]; then
    # Some GitHub versions refuse an App JWT on /users; the bot user is public.
    fm_gh_api GET "/users/$slug%5Bbot%5D" '' '' || return 1
  fi
  [ "$FM_GH_API_STATUS" = 200 ] || { printf 'fm-gh-identity: GitHub answered %s reading the bot user %s[bot]\n' "$FM_GH_API_STATUS" "$slug" >&2; return 1; }
  uid=$(printf '%s' "$FM_GH_API_BODY" | jq -r '.id // empty' 2>/dev/null)
  case "$uid" in ''|*[!0-9]*) printf 'fm-gh-identity: unexpected bot user answer\n' >&2; return 1 ;; esac
  name="${slug}[bot]"
  email="$uid+${slug}[bot]@users.noreply.github.com"
  write_private "$file" "app_id=$APP_ID"$'\n'"name=$name"$'\n'"email=$email" || true
  printf '%s\t%s' "$name" "$email"
}


# user_identity: print "<name>\t<email>" for the token's own account.
user_identity() {
  local token login uid
  token=$(fm_gh_read_token_file "$TOKEN_FILE") || return 1
  fm_gh_api GET /user token "$token" || { printf 'fm-gh-identity: could not reach GitHub to read the token account\n' >&2; return 1; }
  [ "$FM_GH_API_STATUS" = 200 ] || { printf 'fm-gh-identity: GitHub answered %s reading the token account; check the token\n' "$FM_GH_API_STATUS" >&2; return 1; }
  login=$(printf '%s' "$FM_GH_API_BODY" | jq -r '.login // empty' 2>/dev/null)
  uid=$(printf '%s' "$FM_GH_API_BODY" | jq -r '.id // empty' 2>/dev/null)
  case "$login" in ''|*[!A-Za-z0-9-]*) printf 'fm-gh-identity: unexpected token account answer\n' >&2; return 1 ;; esac
  case "$uid" in ''|*[!0-9]*) printf 'fm-gh-identity: unexpected token account answer\n' >&2; return 1 ;; esac
  printf '%s\t%s' "$login" "$uid+$login@users.noreply.github.com"
}

identity() {
  case "$KIND" in
    app) app_identity ;;
    *) user_identity ;;
  esac
}

# can_write <slug>: 0 when the identity can push to <slug>; 3 when it cannot
# (no App installation, no access, or read-only access); 1 on failure.
can_write() {
  local slug=$1 token push
  if [ "$KIND" = app ]; then
    installation_id "$slug" 1 >/dev/null
    return
  fi
  token=$(fm_gh_read_token_file "$TOKEN_FILE") || return 1
  fm_gh_api GET "/repos/$slug" token "$token" || {
    printf 'fm-gh-identity: could not reach GitHub to check access to %s\n' "$slug" >&2
    return 1
  }
  case "$FM_GH_API_STATUS" in
    200) ;;
    403|404) return 3 ;;
    *) printf 'fm-gh-identity: GitHub answered %s checking access to %s\n' "$FM_GH_API_STATUS" "$slug" >&2; return 1 ;;
  esac
  push=$(printf '%s' "$FM_GH_API_BODY" | jq -r '.permissions.push // false' 2>/dev/null)
  [ "$push" = true ] || return 3
}

# worker_token <slug>: print the token a worker uses for <slug>.
worker_token() {
  if [ "$KIND" = app ]; then
    mint_token "$1"
  else
    fm_gh_read_token_file "$TOKEN_FILE" || { printf 'fm-gh-identity: the token file %s is no longer usable\n' "$TOKEN_FILE" >&2; return 1; }
  fi
}

# Profile records written by prepare-worker and read by the pane-time steps.
PROFILE_HOME=
PROFILE_REPO=
PROFILE_NAME=
PROFILE_EMAIL=

read_profile() {
  local dir=$1 file
  file="$dir/profile"
  [ -f "$file" ] && [ ! -L "$file" ] || { printf 'fm-gh-identity: %s has no worker profile\n' "$dir" >&2; return 1; }
  PROFILE_HOME=$(sed -n 's/^home=//p' "$file")
  PROFILE_REPO=$(sed -n 's/^repo=//p' "$file")
  PROFILE_NAME=$(sed -n 's/^name=//p' "$file")
  PROFILE_EMAIL=$(sed -n 's/^email=//p' "$file")
  case "$PROFILE_HOME" in /*) ;; *) printf 'fm-gh-identity: malformed worker profile %s\n' "$file" >&2; return 1 ;; esac
  fm_gh_slug_ok "$PROFILE_REPO" && [ -n "$PROFILE_NAME" ] && [ -n "$PROFILE_EMAIL" ] \
    || { printf 'fm-gh-identity: malformed worker profile %s\n' "$file" >&2; return 1; }
  set_home "$PROFILE_HOME"
}

quote_sq() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

action_status() {
  local slug=$1 ident rc=0
  fm_gh_slug_ok "$slug" || die "expected owner/repo, got: $slug"
  load_config || exit 1
  cache_dir || die "cannot create the private cache under $CACHE"
  ident=$(identity) || exit 1
  can_write "$slug" || rc=$?
  if [ "$rc" -eq 3 ]; then
    printf 'cannot-write: %s (kind=%s identity %s)\n' "$slug" "$KIND" "${ident%%$'\t'*}"
    exit 3
  fi
  [ "$rc" -eq 0 ] || exit 1
  printf 'can-write: %s kind=%s name=%s email=%s\n' "$slug" "$KIND" "${ident%%$'\t'*}" "${ident#*$'\t'}"
}

action_slug_of() {
  local wt=$1 url slug
  url=$(git -C "$wt" config --get remote.origin.url 2>/dev/null) || exit 3
  slug=$(fm_gh_slug_from_url "$url") || exit 3
  printf '%s\n' "$slug"
}

action_check_remotes() {
  local wt=$1 urls url authority effective
  urls=$(git -C "$wt" config --get-all remote.origin.url 2>/dev/null) || urls=
  effective=$(git -C "$wt" config --get-all remote.origin.pushurl 2>/dev/null) || effective=
  urls="$urls"$'\n'"$effective"
  effective=$(git -C "$wt" remote get-url --all origin 2>/dev/null) || die "could not inspect origin fetch URLs; remove embedded credentials from the remote URL"
  urls="$urls"$'\n'"$effective"
  effective=$(git -C "$wt" remote get-url --push --all origin 2>/dev/null) || die "could not inspect origin push URLs; remove embedded credentials from the remote URL"
  urls="$urls"$'\n'"$effective"
  while IFS= read -r url; do
    case "$url" in
      http://*|https://*)
        authority=${url#*://}
        authority=${authority%%/*}
        case "$authority" in *@*) die "remove embedded credentials from the remote URL before using config/github-identity" ;; esac
        ;;
      ssh://*)
        authority=${url#*://}
        authority=${authority%%/*}
        case "$authority" in *:*@*) die "remove embedded credentials from the remote URL before using config/github-identity" ;; esac
        ;;
    esac
  done <<<"$urls"
}

action_prepare_worker() {
  local dir=$1 slug=$2 ident rc=0 home real_gh_note
  fm_gh_slug_ok "$slug" || die "expected owner/repo, got: $slug"
  case "$dir" in /*) ;; *) die "worker directory must be absolute: $dir" ;; esac
  home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || die "cannot resolve FM_HOME $FM_HOME"
  set_home "$home"
  load_config || exit 1
  cache_dir || die "cannot create the private cache under $CACHE"
  ident=$(identity) || exit 1
  can_write "$slug" || rc=$?
  [ "$rc" -eq 0 ] || exit "$rc"
  real_gh_note="# Auto-generated by fm-gh-identity.sh prepare-worker; runs gh as the configured identity."
  rm -rf -- "$dir"
  (umask 077 && mkdir -p "$dir/bin" "$dir/gh-config") || die "cannot create $dir"
  write_private "$dir/profile" "home=$home"$'\n'"repo=$slug"$'\n'"name=${ident%%$'\t'*}"$'\n'"email=${ident#*$'\t'}" \
    || die "cannot write $dir/profile"
  printf '%s\n' '#!/usr/bin/env bash' "$real_gh_note" \
    "exec $(quote_sq "$SELF") gh $(quote_sq "$dir") \"\$@\"" > "$dir/bin/gh" || die "cannot write the gh wrapper"
  chmod 0700 "$dir/bin/gh" || die "cannot make the gh wrapper executable"
  printf 'prepared: %s as %s\n' "$slug" "${ident%%$'\t'*}"
}

action_env_file() {
  local dir=$1 out=$2 count=${GIT_CONFIG_COUNT:-0} tmp helper n line i
  local -a keys values
  dir=$(CDPATH='' cd -- "$dir" 2>/dev/null && pwd -P) || die "cannot resolve worker directory $1"
  read_profile "$dir" || exit 1
  case "$count" in *[!0-9]*) die "invalid inherited GIT_CONFIG_COUNT" ;; esac
  while [ "${count#0}" != "$count" ]; do count=${count#0}; done
  count=${count:-0}
  if [ "${#count}" -gt 9 ]; then die "inherited GIT_CONFIG_COUNT cannot be extended"; fi
  helper="!$(quote_sq "$SELF") git-credential $(quote_sq "$dir")"
  # The empty helper first clears every inherited helper for github.com, so
  # neither the owner's stored login nor gh's own helper can answer instead.
  keys=(credential.https://github.com.helper credential.https://github.com.helper
    credential.https://github.com.useHttpPath transfer.credentialsInUrl
    url.https://github.com/.insteadOf url.https://github.com/.insteadOf)
  values=('' "$helper" true die 'git@github.com:' 'ssh://git@github.com/')
  line="export PATH=$(quote_sq "$dir/bin:${PATH:-}") GH_CONFIG_DIR=$(quote_sq "$dir/gh-config")"
  line="$line GIT_TERMINAL_PROMPT='0'"
  line="$line GIT_AUTHOR_NAME=$(quote_sq "$PROFILE_NAME") GIT_AUTHOR_EMAIL=$(quote_sq "$PROFILE_EMAIL")"
  line="$line GIT_COMMITTER_NAME=$(quote_sq "$PROFILE_NAME") GIT_COMMITTER_EMAIL=$(quote_sq "$PROFILE_EMAIL")"
  n=$count
  for i in "${!keys[@]}"; do
    line="$line GIT_CONFIG_KEY_$n=$(quote_sq "${keys[$i]}") GIT_CONFIG_VALUE_$n=$(quote_sq "${values[$i]}")"
    n=$((n + 1))
  done
  line="$line GIT_CONFIG_COUNT=$n"
  tmp=$(umask 077; mktemp "$out.XXXXXX") || exit 1
  if ! printf '%s\n' "$line" > "$tmp" || ! mv -f -- "$tmp" "$out"; then
    rm -f -- "$tmp"
    exit 1
  fi
}

action_git_credential() {
  local dir=$1 op=${2:-} line protocol='' host='' path='' slug token rc=0 supplied=0
  [ "$op" = get ] || { cat >/dev/null; exit 0; }
  while IFS= read -r line && [ -n "$line" ]; do
    case "$line" in
      protocol=*) protocol=${line#protocol=} ;;
      host=*) host=${line#host=} ;;
      path=*) path=${line#path=} ;;
      username=*|password=*) supplied=1 ;;
    esac
  done
  [ "$protocol" = https ] && [ "$host" = github.com ] || exit 0
  if [ "$supplied" -eq 1 ]; then
    printf 'quit=1\n'
    die "remove embedded credentials from the remote URL before using config/github-identity"
  fi
  read_profile "$dir" || { printf 'quit=1\n'; exit 1; }
  slug=${path%.git}
  slug=${slug%/}
  [ -n "$slug" ] || slug=$PROFILE_REPO
  fm_gh_slug_ok "$slug" || { printf 'quit=1\n'; die "invalid GitHub repository: $slug"; }
  load_config || { printf 'quit=1\n'; exit 1; }
  cache_dir || { printf "fm-gh-identity: cannot use the private cache under %s\n" "$CACHE" >&2; printf 'quit=1\n'; exit 1; }
  token=$(worker_token "$slug") || rc=$?
  if [ "$rc" -ne 0 ]; then
    [ "$rc" -ne 3 ] || printf 'fm-gh-identity: the GitHub App is not installed for %s, so this worker cannot authenticate to it\n' "$slug" >&2
    printf 'quit=1\n'
    die "cannot authenticate to $slug with config/github-identity; grant access/install the App, or remove config/github-identity"
  fi
  printf 'username=x-access-token\npassword=%s\n' "$token"
}

# real_gh <shim-bin>: the first gh on PATH that is not this worker's wrapper.
real_gh() {
  local skip=$1 entry
  local IFS=:
  for entry in $PATH; do
    [ -n "$entry" ] || continue
    [ "$entry" = "$skip" ] && continue
    if [ -x "$entry/gh" ] && [ ! -d "$entry/gh" ]; then
      printf '%s' "$entry/gh"
      return 0
    fi
  done
  return 1
}

action_gh() {
  local dir=$1 gh_bin token rc=0
  shift
  dir=$(CDPATH='' cd -- "$dir" 2>/dev/null && pwd -P) || die "cannot resolve worker directory"
  read_profile "$dir" || exit 1
  gh_bin=$(real_gh "$dir/bin") || die "gh is not installed on PATH"
  load_config || exit 1
  cache_dir || die "cannot create the private cache under $CACHE"
  token=$(worker_token "$PROFILE_REPO") || rc=$?
  if [ "$rc" -eq 3 ]; then
    die "the GitHub App cannot write to $PROFILE_REPO; grant access/install the App, or remove config/github-identity"
  fi
  [ "$rc" -eq 0 ] || exit 1
  GH_TOKEN=$token GH_CONFIG_DIR="$dir/gh-config" exec "$gh_bin" "$@"
}

case "${1:-}" in
  status) [ "$#" -eq 2 ] || { usage >&2; exit 2; }; action_status "$2" ;;
  check-remotes) [ "$#" -eq 2 ] || { usage >&2; exit 2; }; action_check_remotes "$2" ;;
  slug-of) [ "$#" -eq 2 ] || { usage >&2; exit 2; }; action_slug_of "$2" ;;
  prepare-worker) [ "$#" -eq 3 ] || { usage >&2; exit 2; }; action_prepare_worker "$2" "$3" ;;
  env-file) [ "$#" -eq 3 ] || { usage >&2; exit 2; }; action_env_file "$2" "$3" ;;
  git-credential) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; action_git_credential "$2" "${3:-}" ;;
  gh) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; dir=$2; shift 2; action_gh "$dir" "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
