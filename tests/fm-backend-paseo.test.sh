#!/usr/bin/env bash
# Portable contract tests for the Paseo adapter.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-backend-paseo-tests)
FB="$TMP_ROOT/bin"
mkdir -p "$FB"
STATUS="$TMP_ROOT/status"
printf 'running\n' >"$STATUS"
LOG="$TMP_ROOT/log"
ENV_FILE="$TMP_ROOT/paseo.env"
printf 'export OPENAI_API_KEY=super-secret\n' >"$ENV_FILE"
chmod 600 "$ENV_FILE"
cat > "$FB/paseo" <<'SH'
#!/usr/bin/env bash
printf '%s|%s\n' "${PASEO_AGENT_ID-unset}" "$*" >> "$FM_PASEO_LOG"
case "$*" in
  "daemon status") exit 0 ;;
  "provider diagnostic claude")
    case "${FM_PASEO_CLAUDE_DIAGNOSTIC:-failed}" in
      unavailable) printf 'Status: Unavailable\n' ;;
      available) printf 'Status: Available\n' ;;
      *) exit 1 ;;
    esac
    ;;
  inspect\ *) printf '{"status":"%s"}\n' "$(cat "$FM_PASEO_STATUS")" ;;
  logs\ *)
    [ "${FM_PASEO_LOGS_FAIL:-0}" = 1 ] && exit 1
    [ "${FM_PASEO_LOGS_EMPTY:-0}" = 1 ] && printf '[]\n' || printf '[{"message":"timeline"}]\n'
    ;;
  send\ *)
    [ "${FM_PASEO_SEND_FAIL:-0}" = 1 ] && exit 1
    printf 'accepted by paseo\n'
    ;;
  stop\ *) printf 'stopped\n' >> "$FM_PASEO_LOG"; printf 'idle\n' >"$FM_PASEO_STATUS" ;;
  archive\ *) printf 'archived\n' >> "$FM_PASEO_LOG"; printf 'archived\n' >"$FM_PASEO_STATUS" ;;
  "run "*)
    env_file=
    previous=
    for arg in "$@"; do
      case "$previous:$arg" in
        --env:BASH_ENV=*) env_file=${arg#BASH_ENV=} ;;
      esac
      previous=$arg
    done
    if [ -n "$env_file" ]; then
      BASH_ENV="$env_file" bash -c '[ "$OPENAI_API_KEY" = super-secret ]' || exit 1
      printf 'consumed\n' >>"$FM_PASEO_CONSUMED"
    fi
    printf 'Created workspace wks-test\n{"agentId":"agent-test","cwd":"/tmp/fm-test"}\n'
    ;;
esac
exit 0
SH
chmod +x "$FB/paseo"
export PATH="$FB:$PATH" FM_PASEO_LOG="$LOG" FM_PASEO_STATUS="$STATUS" FM_PASEO_CONSUMED="$TMP_ROOT/consumed"
. "$(dirname "${BASH_SOURCE[0]}")/../bin/fm-backend.sh"
fm_backend_source paseo

assert_contains "$(fm_backend_paseo_provider codex)" codex "Codex maps to Paseo"
if fm_backend_paseo_provider claude >/dev/null 2>&1; then fail "disabled Claude provider was accepted"; fi
export FM_PASEO_CLAUDE_DIAGNOSTIC=unavailable
if fm_backend_paseo_provider claude >/dev/null 2>&1; then fail "semantically unavailable Claude provider was accepted"; fi
export FM_PASEO_CLAUDE_DIAGNOSTIC=available
assert_contains "$(fm_backend_paseo_provider claude)" claude "available Claude provider maps to Paseo"
assert_contains "$(fm_backend_paseo_agent_state agent-test)" unverified "Paseo liveness stays unverified"
assert_contains "$(fm_backend_paseo_busy_state agent-test)" busy "Paseo running status is busy"
printf 'error\n' >"$STATUS"
assert_contains "$(fm_backend_paseo_busy_state agent-test)" unknown "Paseo error status is not healthy idle"
printf 'running\n' >"$STATUS"
assert_contains "$(fm_backend_paseo_capture agent-test 4)" timeline "Paseo capture retains timeline logs"
if fm_backend_paseo_capture agent-test 4 | grep -q 'Paseo status'; then fail "Paseo status leaked into diagnostics"; fi
export FM_PASEO_LOGS_EMPTY=1
[ -z "$(fm_backend_paseo_capture agent-test 4)" ] || fail "valid empty Paseo logs should remain empty"
export FM_PASEO_LOGS_FAIL=1
if fm_backend_paseo_capture agent-test 4 >/dev/null 2>&1; then fail "failed Paseo logs command was treated as empty success"; fi
unset FM_PASEO_LOGS_EMPTY FM_PASEO_LOGS_FAIL
if [ -n "$(fm_backend_paseo_send_text_submit agent-test hello)" ]; then fail "Paseo send leaked provider output as a verdict"; fi
export FM_PASEO_SEND_FAIL=1
if fm_backend_paseo_send_text_submit agent-test hello >/dev/null 2>&1; then fail "failed Paseo send was treated as success"; fi
unset FM_PASEO_SEND_FAIL
fm_backend_paseo_stop_status_proof agent-test 1 0.01
assert_contains "$(fm_backend_paseo_busy_state agent-test)" idle "Paseo stop has native status proof"
fm_backend_paseo_create_task task-test "$PWD" "$PWD/README.md" codex default default local home-tag wks-existing "$ENV_FILE" A=1 B=2 >/dev/null
assert_contains "$(cat "$LOG")" '--workspace wks-existing' "Paseo relaunch targets its workspace"
assert_contains "$(cat "$LOG")" "--env BASH_ENV=$ENV_FILE" "Paseo receives the restricted environment reference"
assert_contains "$(cat "$LOG")" '--env A=1 --env B=2' "Paseo preserves repeated env values"
assert_not_contains "$(cat "$LOG")" 'super-secret' "Paseo never places secret env values in argv"
assert_contains "$(cat "$FM_PASEO_CONSUMED")" consumed "Paseo provider worker consumed the restricted environment reference"

SOURCE="$TMP_ROOT/source"
mkdir -p "$SOURCE"
git -C "$SOURCE" init -q
git -C "$SOURCE" config user.email test@example.com
git -C "$SOURCE" config user.name test
printf 'base\n' >"$SOURCE/file"
git -C "$SOURCE" add file
git -C "$SOURCE" commit -qm base
git -C "$SOURCE" branch -M main
git -C "$SOURCE" checkout -qb feature
fm_backend_paseo_create_task fresh-task "$SOURCE" "$PWD/README.md" codex default default local home-tag '' '' >/dev/null
assert_contains "$(cat "$LOG")" '--base main' "Paseo fresh spawn uses the local default branch, not the feature branch"
if fm_backend_paseo_send_key agent-test Escape >/dev/null 2>&1; then fail "unsupported Paseo key was accepted"; fi
fm_backend_paseo_send_key agent-test C-c >/dev/null
assert_contains "$(cat "$LOG")" agent-test "Paseo control calls reached the stub"
pass "Paseo adapter provider, liveness, root-agent, and control contracts"
