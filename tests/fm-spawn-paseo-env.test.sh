#!/usr/bin/env bash
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-paseo-env)
HOME_DIR="$TMP_ROOT/home"
PROJ_DIR="$TMP_ROOT/project"
WT_DIR="$TMP_ROOT/project-worktree"
FAKEBIN_DIR=$(fm_test_make_spawn_fakebin "$TMP_ROOT/fake" codex)
PASEO_ARGS="$TMP_ROOT/paseo-args"
ID=paseo-env-test

fm_test_spawn_home "$HOME_DIR" codex
fm_git_worktree "$PROJ_DIR" "$WT_DIR" paseo-env-test
fm_test_spawn_brief "$HOME_DIR" "$ID"
printf '%s\n' 'FM_TEST_SET' 'FM_TEST_EMPTY' 'FM_TEST_UNSET' > "$HOME_DIR/config/launch-env-allowlist"
cat > "$FAKEBIN_DIR/paseo" <<'SH'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "daemon status") exit 0 ;;
  "run --background")
    printf '%s\n' "$@" >> "$FM_TEST_PASEO_ARGS"
    printf '{"agentId":"agent-paseo-env","workspaceId":"workspace-paseo-env","worktreePath":"%s"}\n' "$FM_TEST_PASEO_WT"
    ;;
  *) exit 1 ;;
esac
SH
chmod +x "$FAKEBIN_DIR/paseo"

unset FM_TEST_UNSET
out=$(BASH_COMPAT=3.2 FM_TEST_SET=present FM_TEST_EMPTY= \
  FM_TEST_PASEO_ARGS="$PASEO_ARGS" FM_TEST_PASEO_WT="$WT_DIR" \
  fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
  "$ID" "$PROJ_DIR" --mode no-mistakes --yolo off --backend paseo --harness codex)
status=$?
expect_code 0 "$status" "Paseo spawn in Bash 3.2 compatibility mode should succeed: $out"
assert_grep 'FM_TEST_SET=present' "$PASEO_ARGS" "Paseo did not receive a set allowlisted value"
assert_grep 'FM_TEST_EMPTY=' "$PASEO_ARGS" "Paseo did not receive an empty-but-set allowlisted value"
assert_no_grep 'FM_TEST_UNSET=' "$PASEO_ARGS" "Paseo received an unset allowlisted value"
assert_grep "paseo_agent_id=agent-paseo-env" "$HOME_DIR/state/$ID.meta" "successful Paseo spawn did not publish its agent identity"
pass "Paseo forwards set and empty allowlisted values while omitting unset values"
