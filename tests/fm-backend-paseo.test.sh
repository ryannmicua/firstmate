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
cat > "$FB/paseo" <<'SH'
#!/usr/bin/env bash
printf '%s|%s\n' "${PASEO_AGENT_ID-unset}" "$*" >> "$FM_PASEO_LOG"
case "$*" in
  "daemon status") exit 0 ;;
  "provider diagnostic claude") exit 1 ;;
  inspect\ *) printf '{"status":"%s"}\n' "$(cat "$FM_PASEO_STATUS")" ;;
  logs\ *) printf '[{"message":"timeline"}]\n' ;;
  stop\ *) printf 'stopped\n' >> "$FM_PASEO_LOG"; printf 'idle\n' >"$FM_PASEO_STATUS" ;;
  archive\ *) printf 'archived\n' >> "$FM_PASEO_LOG"; printf 'archived\n' >"$FM_PASEO_STATUS" ;;
  "run "*) printf 'Created workspace wks-test\n{"agentId":"agent-test","cwd":"/tmp/fm-test"}\n' ;;
esac
exit 0
SH
chmod +x "$FB/paseo"
export PATH="$FB:$PATH" FM_PASEO_LOG="$LOG" FM_PASEO_STATUS="$STATUS"
. "$(dirname "${BASH_SOURCE[0]}")/../bin/fm-backend.sh"
fm_backend_source paseo

assert_contains "$(fm_backend_paseo_provider codex)" codex "Codex maps to Paseo"
if fm_backend_paseo_provider claude >/dev/null 2>&1; then fail "disabled Claude provider was accepted"; fi
assert_contains "$(fm_backend_paseo_agent_state agent-test)" unverified "Paseo liveness stays unverified"
assert_contains "$(fm_backend_paseo_busy_state agent-test)" busy "Paseo running status is busy"
assert_contains "$(fm_backend_paseo_capture agent-test 4)" timeline "Paseo capture retains timeline logs"
if fm_backend_paseo_capture agent-test 4 | grep -q 'Paseo status'; then fail "Paseo status leaked into diagnostics"; fi
fm_backend_paseo_stop_status_proof agent-test 1 0.01
assert_contains "$(fm_backend_paseo_busy_state agent-test)" idle "Paseo stop has native status proof"
fm_backend_paseo_create_task task-test "$PWD" "$PWD/README.md" codex default default local home-tag wks-existing A=1 B=2 >/dev/null
assert_contains "$(cat "$LOG")" '--workspace wks-existing' "Paseo relaunch targets its workspace"
assert_contains "$(cat "$LOG")" '--env A=1 --env B=2' "Paseo preserves repeated env values"
if fm_backend_paseo_send_key agent-test Escape >/dev/null 2>&1; then fail "unsupported Paseo key was accepted"; fi
fm_backend_paseo_send_key agent-test C-c >/dev/null
assert_contains "$(cat "$LOG")" agent-test "Paseo control calls reached the stub"
pass "Paseo adapter provider, liveness, root-agent, and control contracts"
