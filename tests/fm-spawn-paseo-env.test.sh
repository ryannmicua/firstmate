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
    if [ -n "${FM_TEST_PASEO_ABORT_MODE:-}" ]; then
      if [ "${FM_TEST_PASEO_ABORT_MODE:-}" = dirty ]; then
        : > "$FM_TEST_PASEO_WT/.paseo-uncommitted"
      fi
      : > "$FM_TEST_PASEO_TASK_TMP"
      printf '{"agentId":"%s","workspaceId":"%s","worktreePath":"%s"}\n' \
        "$FM_TEST_PASEO_AGENT" "$FM_TEST_PASEO_WORKSPACE" "$FM_TEST_PASEO_WT"
    else
      printf '{"agentId":"agent-paseo-env","workspaceId":"workspace-paseo-env","worktreePath":"%s"}\n' "$FM_TEST_PASEO_WT"
    fi
    ;;
  archive\ *) printf 'archive|%s\n' "$*" >> "$FM_TEST_PASEO_ARGS" ;;
  "workspace archive") printf 'workspace_archive|%s\n' "$*" >> "$FM_TEST_PASEO_ARGS" ;;
  inspect\ *) printf '%s\n' '{"status":"archived"}' ;;
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

run_abort_case() {
  local label=$1 worktree_kind=$2 dirty=$3 id home project worktree returned_worktree agent workspace task_tmp out status
  id="paseo-abort-$label-$$-$RANDOM"
  home="$TMP_ROOT/$id-home"
  project="$TMP_ROOT/$id-project"
  worktree="$TMP_ROOT/$id-worktree"
  returned_worktree=$worktree
  agent="agent-$id"
  workspace="workspace-$id"
  task_tmp="/tmp/fm-$id"
  printf '%s\n' "$task_tmp" >> "$FM_TEST_CLEANUP_REGISTRY"
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$project" "$worktree" "$id"
  fm_test_spawn_brief "$home" "$id"
  if [ "$worktree_kind" = uninspectable ]; then
    returned_worktree="$TMP_ROOT/$id-non-git"
    mkdir -p "$returned_worktree"
  fi

  out=$(FM_TEST_PASEO_ABORT_MODE="$label" \
    FM_TEST_PASEO_ARGS="$PASEO_ARGS" \
    FM_TEST_PASEO_WT="$returned_worktree" \
    FM_TEST_PASEO_AGENT="$agent" \
    FM_TEST_PASEO_WORKSPACE="$workspace" \
    FM_TEST_PASEO_TASK_TMP="$task_tmp" \
    fm_test_run_spawn "$home" "$worktree" "$FAKEBIN_DIR" \
      "$id" "$project" --mode no-mistakes --yolo off --backend paseo --harness codex)
  status=$?
  expect_code 1 "$status" "forced post-return setup failure must abort $label spawn"
  assert_grep "fm-$id" "$PASEO_ARGS" "Paseo run did not create $label task"
  assert_present "$task_tmp" "forced task temporary directory failure did not occur"

  case "$label" in
    dirty)
      assert_contains "$out" "agent $agent and workspace $workspace" "dirty abort did not report both Paseo identities"
      assert_contains "$out" 'uncommitted or untracked changes' "dirty abort did not explain why the workspace was retained"
      assert_present "$worktree/.paseo-uncommitted" "dirty abort removed the worktree change"
      assert_no_grep "archive|archive $agent" "$PASEO_ARGS" "dirty abort archived the Paseo agent"
      assert_no_grep "workspace_archive|workspace archive $workspace" "$PASEO_ARGS" "dirty abort archived the Paseo workspace"
      ;;
    uninspectable)
      assert_contains "$out" "agent $agent and workspace $workspace" "uninspectable abort did not report both Paseo identities"
      assert_contains "$out" 'worktree status could not be inspected' "uninspectable abort did not explain why the workspace was retained"
      assert_no_grep "archive|archive $agent" "$PASEO_ARGS" "uninspectable abort archived the Paseo agent"
      assert_no_grep "workspace_archive|workspace archive $workspace" "$PASEO_ARGS" "uninspectable abort archived the Paseo workspace"
      ;;
    clean)
      assert_grep "archive|archive $agent" "$PASEO_ARGS" "clean worktree abort did not archive the Paseo agent"
      assert_grep "workspace_archive|workspace archive $workspace" "$PASEO_ARGS" "clean worktree abort did not archive the Paseo workspace: $out; calls: $(cat "$PASEO_ARGS")"
      ;;
  esac
}

run_abort_case dirty git 1
run_abort_case uninspectable uninspectable 0
run_abort_case clean git 0
pass "Paseo forwards set and empty allowlisted values while omitting unset values"
