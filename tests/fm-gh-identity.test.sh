#!/usr/bin/env bash
# Behavior tests for bin/fm-gh-identity.sh, the optional GitHub identity
# workers write as (a GitHub App or a user token), and its fm-spawn.sh wiring.
#
# Every GitHub call is answered by the fake curl from tests/fixtures.sh. The
# App private key is a throwaway RSA key generated per run, and every token is
# an invented string, so no case touches a real credential or the network.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

APP="$ROOT/bin/fm-gh-identity.sh"
TMP_ROOT=$(fm_test_tmproot fm-gh-identity)
FAKE_TOKEN=ghs_FakeInstallationToken0001
USER_TOKEN=ghp_FakeMachineUserToken0001
OWNER_LOGIN_SECRET=owner-credential-should-never-answer

command -v openssl >/dev/null 2>&1 || { echo "skip: openssl not installed"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not installed"; exit 0; }

# make_world <name>: a home with an App config and fake GitHub routes.
# Sets HOME_DIR, FAKEBIN, LOG, ROUTES, BODIES.
make_world() {
  local name=$1
  HOME_DIR="$TMP_ROOT/$name/home"
  FAKEBIN=$(fm_fakebin "$TMP_ROOT/$name")
  LOG="$TMP_ROOT/$name/log"
  ROUTES="$TMP_ROOT/$name/routes"
  BODIES="$TMP_ROOT/$name/bodies"
  mkdir -p "$HOME_DIR/config" "$HOME_DIR/state" "$BODIES"
  (umask 077 && openssl genrsa -out "$HOME_DIR/config/github-identity.pem" 2048 2>/dev/null) \
    || fail "could not generate a throwaway key"
  openssl rsa -in "$HOME_DIR/config/github-identity.pem" -pubout -out "$TMP_ROOT/$name/pub.pem" 2>/dev/null
  printf '%s\n' '# test App' 'kind=app' 'app_id=4242' > "$HOME_DIR/config/github-identity"
  printf '%s' '{"id":4242,"slug":"fm-test-app"}' > "$BODIES/app"
  printf '%s' '{"id":99001,"login":"fm-test-app[bot]"}' > "$BODIES/bot"
  printf '%s' '{"id":777,"permissions":{"contents":"write"}}' > "$BODIES/install"
  printf '{"token":"%s","expires_at":"2099-01-01T00:00:00Z"}' "$FAKE_TOKEN" > "$BODIES/token"
  : > "$ROUTES"
  route GET /app 200 app
  route GET '/users/fm-test-app%5Bbot%5D' 200 bot
  route GET /repos/acme/widget/installation 200 install
  route POST /app/installations/777/access_tokens 201 token
  fm_test_fake_github_api "$FAKEBIN" "$LOG" "$ROUTES"
}

route() {  # <method> <glob> <status> <body-name>
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$BODIES/$4" >> "$ROUTES"
}

app() {
  env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE FM_HOME="$HOME_DIR" \
    FM_GH_API_URL=https://api.test.invalid PATH="$FAKEBIN:$PATH" "$APP" "$@"
}

count_calls() {  # <exact call line>
  grep -cxF "$1" "$LOG/calls" 2>/dev/null || true
}

test_prepare_worker_resolves_identity_and_installation() {
  local dir out status jwt sig
  make_world prepare
  dir="$HOME_DIR/state/t1.gh-identity"
  out=$(app prepare-worker "$dir" acme/widget 2>&1)
  status=$?
  expect_code 0 "$status" "prepare-worker should succeed: $out"
  assert_grep 'name=fm-test-app[bot]' "$dir/profile" "profile lacks the bot name"
  assert_grep 'email=99001+fm-test-app[bot]@users.noreply.github.com' "$dir/profile" "profile lacks the bot noreply email"
  assert_grep 'repo=acme/widget' "$dir/profile" "profile lacks the repository"
  [ -x "$dir/bin/gh" ] || fail "prepare-worker did not write the gh wrapper"
  # The App JWT is a real RS256 signature over its header and payload.
  jwt=$(sed -n 's/^Bearer //p' "$LOG/auth" | head -n 1)
  sig=$(printf '%s' "${jwt##*.}" | tr '_-' '/+')
  while [ $(( ${#sig} % 4 )) -ne 0 ]; do sig="$sig="; done
  printf '%s' "$sig" | openssl base64 -d -A > "$TMP_ROOT/prepare/sig.bin"
  printf '%s' "${jwt%.*}" | openssl dgst -sha256 -verify "$TMP_ROOT/prepare/pub.pem" \
    -signature "$TMP_ROOT/prepare/sig.bin" >/dev/null 2>&1 || fail "the App JWT does not verify against the App key"
  assert_no_grep 'Bearer' "$LOG/argv" "a credential rode on curl's command line"
  assert_no_grep "${jwt%%.*}" "$LOG/argv" "the App JWT rode on curl's command line"
  pass "prepare-worker resolves the bot identity and installation with a valid App JWT, credentials off argv"
}

test_prepare_worker_reports_not_installed() {
  local out status
  make_world not-installed
  : > "$ROUTES"
  route GET /app 200 app
  route GET '/users/fm-test-app%5Bbot%5D' 200 bot
  out=$(app prepare-worker "$HOME_DIR/state/t2.gh-identity" acme/other 2>&1)
  status=$?
  expect_code 3 "$status" "an uninstalled repository must exit 3: $out"
  assert_absent "$HOME_DIR/state/t2.gh-identity" "an uninstalled repository still got a worker profile"
  pass "prepare-worker exits 3 when the App is not installed for the repository"
}

test_refuses_shared_private_key() {
  local out status
  make_world shared-key
  chmod 0644 "$HOME_DIR/config/github-identity.pem"
  out=$(app prepare-worker "$HOME_DIR/state/t3.gh-identity" acme/widget 2>&1)
  status=$?
  expect_code 1 "$status" "a group-readable key must refuse"
  assert_contains "$out" "chmod 600" "refusal should say how to fix the key"
  assert_absent "$LOG/calls" "a refused key still called GitHub"
  printf '%s\n' 'kind=app' 'app_id=4242' 'colour=blue' > "$HOME_DIR/config/github-identity"
  chmod 0600 "$HOME_DIR/config/github-identity.pem"
  out=$(app prepare-worker "$HOME_DIR/state/t3.gh-identity" acme/widget 2>&1)
  status=$?
  expect_code 1 "$status" "an unknown config key must refuse"
  assert_contains "$out" "unknown key colour" "refusal should name the unknown key"
  pass "a shared private key or unknown config key refuses before any GitHub call"
}

test_env_file_credentials_identity_and_cache() {
  local dir envf repo out global calls
  make_world envfile
  dir="$HOME_DIR/state/t4.gh-identity"
  app prepare-worker "$dir" acme/widget >/dev/null 2>&1 || fail "prepare-worker failed"
  envf="$TMP_ROOT/envfile/env.sh"
  global="$TMP_ROOT/envfile/gitconfig"
  printf '[credential]\n\thelper = "!f() { echo password=%s; }; f"\n' "$OWNER_LOGIN_SECRET" > "$global"
  GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0='*' \
    GIT_CONFIG_KEY_1=core.hooksPath GIT_CONFIG_VALUE_1=/nonexistent \
    PATH="$FAKEBIN:$PATH" app env-file "$dir" "$envf" || fail "env-file failed"
  repo="$TMP_ROOT/envfile/repo"
  git init -q "$repo"
  # shellcheck disable=SC2016 # The child shell expands its own arguments.
  out=$(env -i HOME="$TMP_ROOT/envfile" PATH="$FAKEBIN:$PATH" GIT_CONFIG_GLOBAL="$global" GIT_CONFIG_NOSYSTEM=1 \
    FM_GH_API_URL=https://api.test.invalid \
    GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0='*' \
    GIT_CONFIG_KEY_1=core.hooksPath GIT_CONFIG_VALUE_1=/nonexistent \
    bash -c '. "$1" || exit 9
      cd "$2" || exit 9
      git config --get core.hooksPath
      git ls-remote --get-url git@github.com:acme/widget.git
      printf "protocol=https\nhost=github.com\npath=acme/widget.git\n\n" | git credential fill | sed -n "s/^password=//p"
      printf "protocol=https\nhost=github.com\npath=acme/widget.git\n\n" | git credential fill | sed -n "s/^password=//p"
      git commit -q --allow-empty -m probe && git log -1 --format="%an <%ae>|%cn <%ce>"
      command -v gh
      printf "%s\n" "$GH_CONFIG_DIR"' _ "$envf" "$repo" 2>&1)
  assert_contains "$out" "/nonexistent" "the inherited GIT_CONFIG entries were dropped"
  assert_contains "$out" "https://github.com/acme/widget.git" "SSH origins are not rewritten to HTTPS"
  [ "$(printf '%s\n' "$out" | grep -cxF "$FAKE_TOKEN")" = 2 ] || fail "git credential did not answer with the App token: $out"
  assert_not_contains "$out" "$OWNER_LOGIN_SECRET" "the owner's credential helper still answered"
  assert_contains "$out" "fm-test-app[bot] <99001+fm-test-app[bot]@users.noreply.github.com>|fm-test-app[bot] <99001+fm-test-app[bot]@users.noreply.github.com>" \
    "commits are not attributed to the App's bot user"
  assert_contains "$out" "$dir/bin/gh" "the gh wrapper is not first on PATH"
  assert_contains "$out" "$dir/gh-config" "gh is not pointed at an empty config directory"
  calls=$(count_calls "POST /app/installations/777/access_tokens")
  [ "$calls" = 1 ] || fail "a cached token was minted again ($calls mints)"
  assert_grep '"repositories":["widget"]' "$LOG/bodies" "the token was not scoped to the one repository"
  pass "env-file routes git through the App token, clears inherited helpers, sets the bot identity, and caches the token"
}

test_token_refresh_and_gh_wrapper() {
  local dir realbin out calls
  make_world refresh
  dir="$HOME_DIR/state/t5.gh-identity"
  app prepare-worker "$dir" acme/widget >/dev/null 2>&1 || fail "prepare-worker failed"
  realbin="$TMP_ROOT/refresh/realbin"
  mkdir -p "$realbin"
  # shellcheck disable=SC2016 # The fake gh expands its own environment.
  printf '%s\n' '#!/usr/bin/env bash' \
    "[ \"\$GH_TOKEN\" = '$FAKE_TOKEN' ] && echo token-ok" \
    'echo "config=$GH_CONFIG_DIR args=$*"' > "$realbin/gh"
  chmod +x "$realbin/gh"
  out=$(env FM_GH_API_URL=https://api.test.invalid PATH="$dir/bin:$FAKEBIN:$realbin:$PATH" gh pr list 2>&1)
  assert_contains "$out" token-ok "the gh wrapper did not hand the real gh the App token"
  assert_contains "$out" "config=$dir/gh-config args=pr list" "the gh wrapper changed gh's arguments or config"
  # A cached token with under ten minutes left is replaced, not reused.
  printf 'expires=%s\ntoken=%s\n' "$(( $(date +%s) + 300 ))" ghs_NearlyExpired > "$HOME_DIR/state/gh-identity/tokens/4242-acme__widget"
  chmod 0600 "$HOME_DIR/state/gh-identity/tokens/4242-acme__widget"
  out=$(env FM_GH_API_URL=https://api.test.invalid PATH="$dir/bin:$FAKEBIN:$realbin:$PATH" gh api user 2>&1)
  assert_contains "$out" token-ok "a nearly expired token was not refreshed"
  calls=$(count_calls "POST /app/installations/777/access_tokens")
  [ "$calls" = 2 ] || fail "expected one fresh mint after expiry, saw $calls mints"
  pass "the gh wrapper runs the real gh with a fresh App token and refreshes a nearly expired one"
}

test_slug_of() {
  local repo
  repo="$TMP_ROOT/slug/repo"
  mkdir -p "$TMP_ROOT/slug"
  git init -q "$repo"
  git -C "$repo" remote add origin git@github.com:example-org/example-app.git
  [ "$("$APP" slug-of "$repo")" = example-org/example-app ] || fail "scp-form origin not parsed"
  git -C "$repo" remote set-url origin https://github.com/example-user/thing
  [ "$("$APP" slug-of "$repo")" = example-user/thing ] || fail "https origin not parsed"
  git -C "$repo" remote set-url origin https://gitlab.com/example-user/thing.git
  "$APP" slug-of "$repo" >/dev/null 2>&1 && fail "a non-GitHub origin was accepted"
  pass "slug-of reads github.com origins and rejects other hosts"
}

test_spawn_wires_app_identity() {
  local case_dir home proj wt fakebin launchlog id=gh-identity-z1 out status launch result
  case_dir="$TMP_ROOT/spawn"
  make_world spawn
  home=$HOME_DIR
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  : > "$launchlog"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  cp "$FAKEBIN/curl" "$fakebin/curl"
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$proj" "$wt" "wt-gh-identity"
  printf '#!/usr/bin/env bash\nreal_git=%q\nlocal_origin=%q\n' "$(command -v git)" "$proj.origin.git" > "$fakebin/git"
  cat >> "$fakebin/git" <<'SH'
args=("$@")
fetch=0
refspec=0
for arg in "${args[@]}"; do
  case "$arg" in fetch) fetch=2 ;; ls-remote) fetch=1 ;; +refs/*) refspec=1 ;; esac
done
for arg in "${args[@]}"; do
  [ "$arg" != --get-url ] || fetch=0
done
for i in "${!args[@]}"; do
  if [ "$fetch" != 0 ] && [ "${args[$i]}" = origin ]; then args[$i]=$local_origin; fi
  if [ "${args[$i]}" = --auto ]; then
    args[$i]=$("$real_git" --git-dir="$local_origin" symbolic-ref --short HEAD) || exit 1
  fi
done
if [ "$fetch" = 2 ] && [ "$refspec" = 0 ]; then args+=('+refs/heads/*:refs/remotes/origin/*'); fi
export GIT_SSH_COMMAND=false
exec "$real_git" "${args[@]}"
SH
  chmod +x "$fakebin/git"
  git -C "$proj" remote set-url origin git@github.com:acme/widget.git
  fm_test_spawn_brief "$home" "$id"
  out=$(FM_FAKE_LAUNCH_LOG="$launchlog" FM_GH_API_URL=https://api.test.invalid \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" \
    --harness 'git var GIT_AUTHOR_IDENT; command -v gh' --mode direct-PR --yolo off)
  status=$?
  expect_code 0 "$status" "spawn with a configured App should succeed: $out"
  [ -f "$home/state/$id.gh-identity/profile" ] || fail "spawn did not prepare the App worker profile"
  launch=$(cat "$launchlog")
  assert_contains "$launch" "fm-gh-identity.sh' env-file" "the launch does not source the identity env file"
  result=$(env HOME="$case_dir" ENV= BASH_ENV= /bin/bash -c "cd '$wt' && $launch" 2>&1)
  assert_contains "$result" "fm-test-app[bot] <99001+fm-test-app[bot]@users.noreply.github.com>" "the worker does not commit as the App"
  assert_contains "$result" "$id.gh-identity/bin/gh" "the worker's gh is not the identity wrapper"

  id=gh-identity-z2
  fm_test_spawn_brief "$home" "$id"
  printf '%s\t%s\t%s\t%s\n' GET /repos/acme/widget/installation 404 "$BODIES/app" > "$ROUTES.new"
  grep -v 'installation' "$ROUTES" >> "$ROUTES.new"
  mv "$ROUTES.new" "$ROUTES"
  git -C "$proj" worktree add --quiet -b wt-gh-identity-2 "$wt-2"
  : > "$launchlog"
  out=$(FM_FAKE_LAUNCH_LOG="$launchlog" FM_GH_API_URL=https://api.test.invalid \
    fm_test_run_spawn "$home" "$wt-2" "$fakebin" "$id" "$proj" \
    --harness 'echo worker-ran' --mode direct-PR --yolo off)
  status=$?
  expect_code 1 "$status" "spawn for an uninstalled repository must refuse: $out"
  assert_contains "$out" "cannot write to acme/widget" "spawn did not report the missing installation"
  [ ! -s "$launchlog" ] || fail "a refused identity still launched a worker"
  assert_contains "$out" "grant access/install the App" "refusal lacks remediation"
  id=gh-identity-z3
  fm_test_spawn_brief "$home" "$id"
  git -C "$proj" remote set-url origin "$proj.origin.git"
  git -C "$proj" worktree add --quiet -b wt-gh-identity-3 "$wt-3"
  : > "$launchlog"
  out=$(FM_FAKE_LAUNCH_LOG="$launchlog" FM_GH_API_URL=https://api.test.invalid \
    fm_test_run_spawn "$home" "$wt-3" "$fakebin" "$id" "$proj" \
    --harness 'echo worker-ran' --mode direct-PR --yolo off)
  status=$?
  expect_code 1 "$status" "spawn without a github.com origin must refuse: $out"
  assert_contains "$out" "$proj" "origin refusal lacks the repository"
  assert_contains "$out" "remove config/github-identity" "origin refusal lacks remediation"
  [ ! -s "$launchlog" ] || fail "a non-GitHub origin launched a worker"
  pass "spawn runs a configured worker as the App and refuses when it is not installed"
}

# make_token_world <name>: a home whose identity is a user token.
make_token_world() {
  local name=$1
  make_world "$name"
  rm -f "$HOME_DIR/config/github-identity.pem"
  printf '%s\n' 'kind=token' > "$HOME_DIR/config/github-identity"
  (umask 077 && printf '%s\n' "$USER_TOKEN" > "$HOME_DIR/config/github-identity.token")
  printf '%s' '{"login":"machine-bot","id":5150}' > "$BODIES/user"
  printf '%s' '{"full_name":"acme/widget","permissions":{"admin":false,"push":true,"pull":true}}' > "$BODIES/repo-rw"
  printf '%s' '{"full_name":"acme/readonly","permissions":{"admin":false,"push":false,"pull":true}}' > "$BODIES/repo-ro"
  : > "$ROUTES"
  route GET /user 200 user
  route GET /repos/acme/widget 200 repo-rw
  route GET /repos/acme/readonly 200 repo-ro
}

test_token_identity_prepares_and_answers() {
  local dir envf out status realbin
  make_token_world token
  dir="$HOME_DIR/state/t7.gh-identity"
  out=$(app prepare-worker "$dir" acme/widget 2>&1)
  status=$?
  expect_code 0 "$status" "a writable repository should prepare: $out"
  assert_grep 'name=machine-bot' "$dir/profile" "profile lacks the token account login"
  assert_grep 'email=5150+machine-bot@users.noreply.github.com' "$dir/profile" "profile lacks the account noreply email"
  out=$(app prepare-worker "$HOME_DIR/state/t8.gh-identity" acme/readonly 2>&1)
  status=$?
  expect_code 3 "$status" "a read-only repository must exit 3: $out"
  out=$(app prepare-worker "$HOME_DIR/state/t9.gh-identity" acme/missing 2>&1)
  status=$?
  expect_code 3 "$status" "an inaccessible repository must exit 3: $out"
  envf="$TMP_ROOT/token/env.sh"
  realbin="$TMP_ROOT/token/realbin"
  mkdir -p "$realbin"
  printf '%s\n' '#!/usr/bin/env bash' "[ \"\$GH_TOKEN\" = '$USER_TOKEN' ] && echo token-ok" > "$realbin/gh"
  chmod +x "$realbin/gh"
  # The env file captures PATH, so the stand-in gh must precede any real one.
  env -u GIT_CONFIG_COUNT PATH="$realbin:$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" "$APP" env-file "$dir" "$envf" \
    || fail "env-file failed"
  # shellcheck disable=SC2016 # The child shell expands its own arguments.
  out=$(env -i HOME="$TMP_ROOT/token" PATH="$realbin:$FAKEBIN:$PATH" GIT_CONFIG_NOSYSTEM=1 \
    FM_GH_API_URL=https://api.test.invalid bash -c '. "$1" || exit 9
      printf "protocol=https\nhost=github.com\npath=acme/widget.git\n\n" | git credential fill | sed -n "s/^password=//p"
      gh pr list' _ "$envf" 2>&1)
  assert_contains "$out" "$USER_TOKEN" "git credential did not answer with the user token"
  assert_contains "$out" token-ok "the gh wrapper did not hand gh the user token"
  assert_no_grep "$USER_TOKEN" "$LOG/argv" "the user token rode on curl's command line"
  assert_absent "$HOME_DIR/state/gh-identity/tokens/4242-acme__widget" "a user token was copied into the cache"
  # Replacing the token file rotates the token without another spawn.
  (umask 077 && printf '%s\n' ghp_RotatedToken0002 > "$HOME_DIR/config/github-identity.token")
  # shellcheck disable=SC2016 # The child shell expands its own arguments.
  out=$(env -i HOME="$TMP_ROOT/token" PATH="$FAKEBIN:$PATH" GIT_CONFIG_NOSYSTEM=1 bash -c '. "$1" || exit 9
      printf "protocol=https\nhost=github.com\npath=acme/widget.git\n\n" | git credential fill | sed -n "s/^password=//p"' _ "$envf" 2>&1)
  assert_contains "$out" ghp_RotatedToken0002 "a replaced token file was not picked up"
  chmod 0644 "$HOME_DIR/config/github-identity.token"
  out=$(app prepare-worker "$dir" acme/widget 2>&1)
  status=$?
  expect_code 1 "$status" "a shared token file must refuse"
  assert_contains "$out" "chmod 600" "the refusal should say how to fix the token file"
  pass "a user-token identity prepares writable repositories only, answers git and gh with its token, and rotates with the file"
}

test_app_permissions_and_cache_binding() {
  local dir out status realbin
  make_world cache-binding
  dir="$HOME_DIR/state/cache.gh-identity"
  app prepare-worker "$dir" acme/widget >/dev/null || fail "initial prepare failed"
  realbin="$TMP_ROOT/cache-binding/realbin"
  mkdir -p "$realbin"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$GH_TOKEN"' > "$realbin/gh"
  chmod +x "$realbin/gh"
  out=$(PATH="$FAKEBIN:$realbin:$PATH" app gh "$dir" api user)
  [ "$out" = "$FAKE_TOKEN" ] || fail "initial token missing"
  printf '%s\n' 'kind=app' 'app_id=4343' > "$HOME_DIR/config/github-identity"
  printf '%s' '{"id":888,"permissions":{"contents":"write"}}' > "$BODIES/install"
  printf '%s' '{"token":"ghs_SecondAppToken","expires_at":"2099-01-01T00:00:00Z"}' > "$BODIES/token"
  route POST /app/installations/888/access_tokens 201 token
  out=$(PATH="$FAKEBIN:$realbin:$PATH" app gh "$dir" api user)
  [ "$out" = ghs_SecondAppToken ] || fail "switching Apps reused the previous token: $out"
  assert_grep 'POST /app/installations/888/access_tokens' "$LOG/calls" "switching Apps reused the previous installation"
  out=$(printf 'protocol=https\nhost=github.com\npath=acme/widget.git\n\n' | app git-credential "$dir" get)
  assert_contains "$out" 'password=ghs_SecondAppToken' "git reused the previous App token"
  printf '%s' '{"id":888,"permissions":{"contents":"read"}}' > "$BODIES/install"
  out=$(app status acme/widget 2>&1); status=$?
  expect_code 3 "$status" "a read-only App must not report can-write: $out"
  out=$(app prepare-worker "$HOME_DIR/state/readonly" acme/widget 2>&1); status=$?
  expect_code 3 "$status" "a read-only App must not prepare a worker: $out"
  assert_absent "$HOME_DIR/state/readonly" "read-only App created a profile"
  rm -f "$HOME_DIR/config/github-identity"
  out=$(printf 'protocol=https\nhost=github.com\npath=acme/widget.git\n\n' | app git-credential "$dir" get 2>&1); status=$?
  expect_code 1 "$status" "missing identity must fail the helper: $out"
  assert_contains "$out" 'quit=1' "helper failure did not stop credential fallback"
  out=$(printf 'protocol=https\nhost=github.com\npath=acme/widget.git\n\n' |
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 \
    git -c credential.helper= \
      -c "credential.helper=!$APP git-credential $dir" \
      -c 'credential.helper=!f() { echo username=owner; echo password=owner-secret; }; f' \
      credential fill 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "git fell through to the owner helper"
  assert_not_contains "$out" 'password=owner-secret' "owner helper answered after identity failure"
  out=$(PATH="$FAKEBIN:$realbin:$PATH" app gh "$dir" api user 2>&1); status=$?
  expect_code 1 "$status" "missing identity must refuse gh: $out"
  assert_not_contains "$out" ghs_SecondAppToken "failed wrapper still invoked gh"
  pass "App caches follow App identity, read-only installations refuse, and missing credentials fail closed"
}

test_paseo_agent_refuses_configured_identity() {
  local kind action id proj wt fakebin out status before after launchlog paseolog
  for kind in ship scout; do
    for action in fresh relaunch; do
      id="identity-$kind-$action"
      make_world "$id"
      proj="$TMP_ROOT/$id/project"
      wt="$TMP_ROOT/$id/worktree"
      fakebin=$(fm_test_make_spawn_fakebin "$TMP_ROOT/$id/fake" codex)
      launchlog="$TMP_ROOT/$id/launch"
      paseolog="$TMP_ROOT/$id/paseo"
      : > "$launchlog"
      : > "$paseolog"
      printf '%s\n' '#!/usr/bin/env bash' \
        'printf "%s\n" "$*" >> "$FM_TEST_IDENTITY_PASEO_LOG"' \
        'case "$*" in "daemon status") exit 0 ;; *) printf "[]\n" ;; esac' > "$fakebin/paseo"
      chmod +x "$fakebin/paseo"
      fm_test_spawn_home "$HOME_DIR" codex
      fm_git_worktree "$proj" "$wt" "branch-$id"
      fm_test_spawn_brief "$HOME_DIR" "$id"
      before=$(git -C "$proj" worktree list --porcelain; git -C "$proj" show-ref)
      if [ "$action" = relaunch ]; then
        printf '%s\n' "kind=$kind" 'backend=paseo-agent' "endpoint_task_id=$id" \
          'window=agent-existing' 'paseo_agent_id=agent-existing' 'paseo_workspace_id=wks-existing' \
          "worktree=$wt" "project=$proj" > "$HOME_DIR/state/$id.meta"
        out=$(FM_TEST_IDENTITY_PASEO_LOG="$paseolog" FM_FAKE_LAUNCH_LOG="$launchlog" \
          fm_test_run_spawn "$HOME_DIR" "$wt" "$fakebin" --relaunch "$id")
      elif [ "$kind" = scout ]; then
        out=$(FM_TEST_IDENTITY_PASEO_LOG="$paseolog" FM_FAKE_LAUNCH_LOG="$launchlog" \
          fm_test_run_spawn "$HOME_DIR" "$wt" "$fakebin" --scout "$id" "$proj" --backend paseo-agent --harness codex)
      else
        out=$(FM_TEST_IDENTITY_PASEO_LOG="$paseolog" FM_FAKE_LAUNCH_LOG="$launchlog" \
          fm_test_run_spawn "$HOME_DIR" "$wt" "$fakebin" "$id" "$proj" \
          --mode direct-PR --yolo off --backend paseo-agent --harness codex)
      fi
      status=$?
      expect_code 1 "$status" "configured identity must refuse $kind $action: $out"
      assert_contains "$out" 'backend=paseo-agent does not apply config/github-identity' "refusal lacks the backend and identity cause"
      assert_contains "$out" 'use a backend that applies the identity or remove config/github-identity' "refusal lacks remediation"
      [ ! -s "$launchlog" ] || fail "refused spawn launched a shell worker"
      [ ! -s "$paseolog" ] || fail "refused spawn reached the Paseo runtime"
      after=$(git -C "$proj" worktree list --porcelain; git -C "$proj" show-ref)
      [ "$before" = "$after" ] || fail "refused spawn mutated worktrees or branches"
      [ -z "$(git -C "$wt" status --porcelain --untracked-files=all)" ] || fail "refused spawn changed the worktree"
    done
  done
  pass "paseo-agent refuses configured identities before runtime or worktree changes for ships, scouts, and relaunches"
}

test_spawn_refuses_embedded_remote_credentials() {
  local variant id proj wt fakebin launchlog out status secret=InventedOwnerToken991
  for variant in fetch push additional-push instead-fetch instead-push push-instead username raw-rewritten; do
    id="embedded-$variant"
    make_world "$id"
    proj="$TMP_ROOT/$id/project"
    wt="$TMP_ROOT/$id/worktree"
    fakebin=$(fm_test_make_spawn_fakebin "$TMP_ROOT/$id/fake" codex)
    launchlog="$TMP_ROOT/$id/launch"
    : > "$launchlog"
    fm_test_spawn_home "$HOME_DIR" codex
    fm_git_worktree "$proj" "$wt" "branch-$id"
    fm_test_spawn_brief "$HOME_DIR" "$id"
    git -C "$proj" remote set-url origin https://github.com/acme/widget.git
    case "$variant" in
      fetch) git -C "$proj" remote set-url origin "https://owner:$secret@github.com/acme/widget.git" ;;
      push) git -C "$proj" config remote.origin.pushurl "https://owner:$secret@github.com/acme/widget.git" ;;
      additional-push)
        git -C "$proj" config --add remote.origin.pushurl https://github.com/acme/widget.git
        git -C "$proj" config --add remote.origin.pushurl "https://owner:$secret@github.com/acme/widget.git"
        ;;
      instead-fetch)
        git -C "$proj" config "url.https://owner:$secret@github.com/.insteadOf" https://github.com/
        ;;
      instead-push)
        git -C "$proj" config remote.origin.pushurl alias:acme/widget.git
        git -C "$proj" config "url.https://owner:$secret@github.com/.insteadOf" alias:
        ;;
      push-instead)
        git -C "$proj" config "url.https://owner:$secret@github.com/.pushInsteadOf" https://github.com/
        ;;
      username) git -C "$proj" remote set-url origin "https://$secret@github.com/acme/widget.git" ;;
      raw-rewritten)
        git -C "$proj" remote set-url origin "https://owner:$secret@github.com/acme/widget.git"
        git -C "$proj" config "url.https://github.com/.insteadOf" "https://owner:$secret@github.com/"
        ;;
    esac
    out=$(FM_FAKE_LAUNCH_LOG="$launchlog" fm_test_run_spawn "$HOME_DIR" "$wt" "$fakebin" "$id" "$proj" \
      --harness 'echo worker-ran' --mode direct-PR --yolo off)
    status=$?
    expect_code 1 "$status" "credential-bearing $variant URL must refuse"
    assert_contains "$out" 'remove embedded credentials from the remote URL' "missing credential remediation for $variant"
    assert_not_contains "$out" "$secret" "spawn leaked embedded credentials for $variant"
    [ ! -s "$launchlog" ] || fail "credential-bearing $variant launched a worker"
  done
  pass "spawn refuses raw and rewritten fetch and push credentials without disclosing them"
}

test_worker_rejects_embedded_credentials() {
  local dir envf repo execdir out status op secret=InventedOwnerToken992
  make_world embedded-worker
  dir="$HOME_DIR/state/worker.gh-identity"
  envf="$TMP_ROOT/embedded-worker/env.sh"
  repo="$TMP_ROOT/embedded-worker/repo"
  execdir="$TMP_ROOT/embedded-worker/git-exec"
  mkdir -p "$execdir"
  app prepare-worker "$dir" acme/widget >/dev/null || fail "worker prepare failed"
  app env-file "$dir" "$envf" || fail "worker environment failed"
  out=$(printf 'protocol=https\nhost=github.com\npath=acme/widget.git\nusername=owner\npassword=%s\n\n' "$secret" |
    app git-credential "$dir" get 2>&1)
  status=$?
  expect_code 1 "$status" "helper accepted supplied credentials"
  assert_contains "$out" 'quit=1' "helper did not stop credential fallback"
  assert_not_contains "$out" "$secret" "helper leaked supplied credentials"
  git init -q "$repo"
  git -C "$repo" -c user.name=Test -c user.email=test@example.invalid commit -q --allow-empty -m initial
  git -C "$repo" remote add origin "https://owner:$secret@github.com/acme/widget.git"
  printf '%s\n' '#!/usr/bin/env bash' ': > "$FM_TEST_TRANSPORT_CALLED"' 'exit 1' > "$execdir/git-remote-https"
  chmod +x "$execdir/git-remote-https"
  for op in fetch push; do
    out=$(env -i HOME="$TMP_ROOT/embedded-worker" PATH="$PATH" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      GIT_EXEC_PATH="$execdir" FM_TEST_TRANSPORT_CALLED="$execdir/called" \
      bash -c '. "$1" || exit 9; if [ "$3" = push ]; then git -C "$2" push origin HEAD:refs/heads/probe; else git -C "$2" fetch origin; fi' _ "$envf" "$repo" "$op" 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "worker $op accepted embedded credentials"
    assert_contains "$out" 'uses plaintext credentials' "worker $op did not reject at the transport boundary"
    assert_not_contains "$out" "$secret" "worker $op exposed embedded credentials"
    assert_absent "$execdir/called" "worker $op passed credentials to the transport"
  done
  pass "worker helper and fetch/push transport reject embedded credentials without disclosure"
}

test_effective_remotes_require_identity_transport() {
  local variant id proj wt fakebin launchlog out status dir envf transport op
  for variant in ssh-port https-port other-repo other-host file-rewrite fetch-rewrite; do
    id="transport-$variant"
    make_world "$id"
    proj="$TMP_ROOT/$id/project"
    wt="$TMP_ROOT/$id/worktree"
    fakebin=$(fm_test_make_spawn_fakebin "$TMP_ROOT/$id/fake" codex)
    launchlog="$TMP_ROOT/$id/launch"
    : > "$launchlog"
    fm_test_spawn_home "$HOME_DIR" codex
    fm_git_worktree "$proj" "$wt" "branch-$id"
    fm_test_spawn_brief "$HOME_DIR" "$id"
    git -C "$proj" remote set-url origin https://github.com/acme/widget.git
    case "$variant" in
      ssh-port) git -C "$proj" config remote.origin.pushurl ssh://git@github.com:22/acme/widget.git ;;
      https-port) git -C "$proj" config remote.origin.pushurl https://github.com:443/acme/widget.git ;;
      other-repo) git -C "$proj" config remote.origin.pushurl https://github.com/acme/other.git ;;
      other-host) git -C "$proj" config remote.origin.pushurl https://example.invalid/acme/widget.git ;;
      file-rewrite) git -C "$proj" config "url.file://$proj.origin.git.pushInsteadOf" https://github.com/acme/widget.git ;;
      fetch-rewrite) git -C "$proj" config url.https://example.invalid/.insteadOf https://github.com/ ;;
    esac
    out=$(FM_FAKE_LAUNCH_LOG="$launchlog" fm_test_run_spawn "$HOME_DIR" "$wt" "$fakebin" "$id" "$proj" \
      --harness 'echo worker-ran' --mode direct-PR --yolo off)
    status=$?
    expect_code 1 "$status" "unsupported effective $variant transport must refuse: $out"
    if [ "$variant" = fetch-rewrite ]; then
      assert_contains "$out" remote.origin.url "refusal lacks fetch setting"
    else
      assert_contains "$out" remote.origin.pushurl "refusal lacks push setting"
    fi
    [ ! -s "$launchlog" ] || fail "unsupported $variant transport launched a worker"
  done
  make_world allowed-transports
  proj="$TMP_ROOT/allowed-transports/repo"
  git init -q "$proj"
  for transport in https://github.com/acme/widget.git git@github.com:acme/widget.git ssh://git@github.com/acme/widget.git; do
    git -C "$proj" config remote.origin.url "$transport"
    git -C "$proj" config remote.origin.pushurl "$transport"
    app check-remotes "$proj" || fail "supported identity transport refused"
  done
  dir="$HOME_DIR/state/transport.gh-identity"
  envf="$TMP_ROOT/allowed-transports/env.sh"
  app prepare-worker "$dir" acme/widget >/dev/null || fail "worker prepare failed"
  app env-file "$dir" "$envf" || fail "worker environment failed"
  git -C "$proj" config remote.origin.url ssh://git@github.com:22/acme/widget.git
  git -C "$proj" config remote.origin.pushurl ssh://git@github.com:22/acme/widget.git
  git -C "$proj" -c user.name=Test -c user.email=test@example.invalid commit -q --allow-empty -m initial
  printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$TMP_ROOT/allowed-transports/ssh"
  chmod +x "$TMP_ROOT/allowed-transports/ssh"
  for op in fetch push; do
    out=$(env -i GIT_SSH_COMMAND="$TMP_ROOT/allowed-transports/ssh" HOME="$TMP_ROOT/allowed-transports" PATH="$PATH" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      bash -c '. "$1" || exit 9; if [ "$3" = push ]; then git -C "$2" push origin HEAD:refs/heads/probe; else git -C "$2" fetch origin; fi' _ "$envf" "$proj" "$op" 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "worker $op allowed SSH bypass"
    assert_contains "$out" "transport 'ssh' not allowed" "worker $op did not enforce HTTPS transport"
  done
  pass "effective remotes require same-repository HTTPS; workers refuse SSH port bypasses"
}

test_prepare_worker_resolves_identity_and_installation
test_prepare_worker_reports_not_installed
test_refuses_shared_private_key
test_env_file_credentials_identity_and_cache
test_token_refresh_and_gh_wrapper
test_slug_of
test_spawn_wires_app_identity
test_token_identity_prepares_and_answers

test_app_permissions_and_cache_binding

test_paseo_agent_refuses_configured_identity

test_spawn_refuses_embedded_remote_credentials
test_worker_rejects_embedded_credentials

test_effective_remotes_require_identity_transport
