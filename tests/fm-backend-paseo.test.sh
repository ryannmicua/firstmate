#!/usr/bin/env bash
# Portable contract tests for the Paseo adapter.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-backend-paseo-tests)
FB="$TMP_ROOT/bin"
mkdir -p "$FB"
LOG="$TMP_ROOT/log"
cat > "$FB/paseo" <<'SH'
#!/usr/bin/env bash
printf '%s|%s\n' "${PASEO_AGENT_ID-unset}" "$*" >> "$FM_PASEO_LOG"
case "$*" in
  "daemon status") exit 0 ;;
  "provider diagnostic claude") exit 1 ;;
  "run "*) printf 'Created workspace wks-test\n{"agentId":"agent-test","cwd":"/tmp/fm-test"}\n' ;;
esac
exit 0
SH
chmod +x "$FB/paseo"
export PATH="$FB:$PATH" FM_PASEO_LOG="$LOG"
. "$(dirname "${BASH_SOURCE[0]}")/../bin/fm-backend.sh"
fm_backend_source paseo

assert_contains "$(fm_backend_paseo_provider codex)" codex "Codex maps to Paseo"
if fm_backend_paseo_provider claude >/dev/null 2>&1; then fail "disabled Claude provider was accepted"; fi
assert_contains "$(fm_backend_paseo_agent_state agent-test)" unverified "Paseo liveness stays unverified"
if fm_backend_paseo_send_key agent-test Escape >/dev/null 2>&1; then fail "unsupported Paseo key was accepted"; fi
fm_backend_paseo_send_key agent-test C-c >/dev/null
assert_contains "$(cat "$LOG")" agent-test "Paseo control calls reached the stub"
pass "Paseo adapter provider, liveness, root-agent, and control contracts"
