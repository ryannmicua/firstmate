#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
RUN_LABEL=${1:?pass a fresh run label}
SOCKET_TAG="$(date -u +%Y%m%d%H%M%S)-$$"
case "$RUN_LABEL" in
  *[!a-zA-Z0-9_-]*|'') echo "invalid run label: $RUN_LABEL" >&2; exit 2 ;;
esac
LAB="$ROOT/.validation-tmp/live/$RUN_LABEL"
mkdir -p "$LAB"

setup_common() {
  local case_dir=$1 socket=$2
  umask 077
  mkdir -p "$case_dir/bin" "$case_dir/home/state" "$case_dir/home/data/paseo-backend-adapter" "$case_dir/home/config" "$case_dir/user-home" "$case_dir/firstmate" "$case_dir/wt"
  printf 'tmux\n' > "$case_dir/home/config/backend"
  cat > "$case_dir/firstmate/AGENTS.md" <<'EOF'
# Isolated live-validation project
Use only the recorded worktree for this task.
EOF
  git -C "$case_dir/firstmate" init -q
  git -C "$case_dir/firstmate" add AGENTS.md
  git -C "$case_dir/firstmate" commit -qm 'Create isolated project fixture'
  printf 'preserved baseline\n' > "$case_dir/wt/README.md"
  git -C "$case_dir/wt" init -q
  git -C "$case_dir/wt" add README.md
  git -C "$case_dir/wt" commit -qm 'Create isolated task fixture'
  git -C "$case_dir/wt" branch -M fm/paseo-backend-adapter
  printf 'unpublished tracked edit\n' >> "$case_dir/wt/README.md"
  printf 'unpublished untracked edit\n' > "$case_dir/wt/untracked-handoff.txt"
  cat > "$case_dir/home/data/paseo-backend-adapter/brief.md" <<'EOF'
# Task
## Captain's intent
Continue the existing Firstmate backend task safely.

## Firstmate spec
Use only the recorded Firstmate worktree.

Delivery contract: mode=no-mistakes
EOF
  {
    printf '%s\n' 'window=firstmate:fm-paseo-backend-adapter'
    printf '%s\n' 'endpoint_task_id=paseo-backend-adapter'
    printf 'worktree=%s\n' "$case_dir/wt"
    printf 'project=%s\n' "$case_dir/firstmate"
    printf '%s\n' 'harness=codex' 'kind=ship' 'mode=no-mistakes' 'yolo=off'
    printf 'tasktmp=%s\n' "$case_dir/tasktmp"
    printf '%s\n' 'model=default' 'effort=default'
  } > "$case_dir/home/state/paseo-backend-adapter.meta"
  if [ "${REAL_CODEX:-0}" != 1 ]; then
    cat > "$case_dir/bin/codex" <<EOF
#!/usr/bin/env bash
printf 'codex invoked:' >> '$LAB/codex-invocations.log'
printf ' %q' "\$@" >> '$LAB/codex-invocations.log'
printf '\\n' >> '$LAB/codex-invocations.log'
exec -a codex /bin/sleep 180
EOF
    chmod +x "$case_dir/bin/codex"
  fi
  cat > "$case_dir/bin/tmux" <<EOF
#!/usr/bin/env bash
exec /usr/bin/tmux -L '$socket' "\$@"
EOF
  chmod +x "$case_dir/bin/tmux"
  export HOME="$case_dir/user-home"
  export PATH="$case_dir/bin:$PATH"
  export FM_TEST_TMUX_SOCKET="$socket"
  export TMUX_TMPDIR="$ROOT"
  mkdir -p "$TMUX_TMPDIR/tmux-$(id -u)"
  chmod 700 "$TMUX_TMPDIR/tmux-$(id -u)"
}

run_handoff() {
  local case_dir=$1 answer_worker=$2 answer_run=$3 output=$4
  local expected_worktree=${5:-"$case_dir/wt"} rc
  set +e
  printf '%s\n%s\n' "$answer_worker" "$answer_run" | \
    timeout 45s env -u TMUX -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
      FM_HOME="$case_dir/home" HOME="$case_dir/user-home" FM_GATE_REFUSE_BYPASS=1 \
      FM_CONTROL_POLL=0.1 FM_CONTROL_EXIT_WAIT=0.2 FM_CONTROL_LAUNCH_WAIT=5 \
      FM_CONTROL_SETTLE_WAIT=0.2 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
      GIT_AUTHOR_NAME='Live Validation' GIT_AUTHOR_EMAIL='live-validation@example.invalid' \
      GIT_COMMITTER_NAME='Live Validation' GIT_COMMITTER_EMAIL='live-validation@example.invalid' \
      "$ROOT/bin/fm-control.sh" paseo-backend-adapter handoff \
        --expect-endpoint firstmate:fm-paseo-backend-adapter \
        --expect-worktree "$expected_worktree" \
        --expect-head "$(git -C "$case_dir/wt" rev-parse HEAD)" \
        --note 'Continue in this exact local copy; preserve all existing changes.' > "$output" 2>&1
  rc=$?
  set -e
  return "$rc"
}

snapshot_case() {
  local case_dir=$1 output=$2 path
  {
    printf 'task_meta_sha256=%s\n' "$(sha256sum "$case_dir/home/state/paseo-backend-adapter.meta" | awk '{print $1}')"
    printf 'brief_sha256=%s\n' "$(sha256sum "$case_dir/home/data/paseo-backend-adapter/brief.md" | awk '{print $1}')"
    printf 'branch=%s\n' "$(git -C "$case_dir/wt" branch --show-current)"
    printf 'HEAD=%s\n' "$(git -C "$case_dir/wt" rev-parse HEAD)"
    printf 'worktree_status=%s\n' "$(git -C "$case_dir/wt" status --porcelain=v1 --untracked-files=all | tr '\n' '|')"
    printf 'README_sha256=%s\n' "$(sha256sum "$case_dir/wt/README.md" | awk '{print $1}')"
    printf 'untracked_sha256=%s\n' "$(sha256sum "$case_dir/wt/untracked-handoff.txt" | awk '{print $1}')"
    for path in "$case_dir"/home/state/*; do
      [ -f "$path" ] || continue
      printf 'state_file=%s:%s\n' "$(basename "$path")" "$(sha256sum "$path" | awk '{print $1}')"
    done
    printf 'sessions=%s\n' "$("$case_dir/bin/tmux" list-sessions -F '#{session_name}')"
    printf 'windows=%s\n' "$("$case_dir/bin/tmux" list-windows -a -F '#{session_name}:#{window_name} #{pane_current_path} #{pane_current_command}')"
  } > "$output"
}

assert_refusal_unchanged() {
  local case_dir=$1 name=$2 answer_worker=$3 answer_run=$4 expected_worktree=$5 expected_error=$6
  local rc=0 endpoint_state
  snapshot_case "$case_dir" "$LAB/$name.before.txt"
  run_handoff "$case_dir" "$answer_worker" "$answer_run" "$LAB/$name.output.txt" "$expected_worktree" || rc=$?
  [ "$rc" -ne 0 ] || {
    printf 'unsafe: %s handoff unexpectedly succeeded\n' "$name" >&2
    exit 1
  }
  grep -Fq -- "$expected_error" "$LAB/$name.output.txt" || {
    printf 'unexpected %s refusal output:\n' "$name" >&2
    cat "$LAB/$name.output.txt" >&2
    exit 1
  }
  snapshot_case "$case_dir" "$LAB/$name.after.txt"
  cmp -s "$LAB/$name.before.txt" "$LAB/$name.after.txt" || {
    printf '%s refusal changed durable task state or endpoint inventory\n' "$name" >&2
    diff -u "$LAB/$name.before.txt" "$LAB/$name.after.txt" >&2 || true
    exit 1
  }
  endpoint_state=$("$case_dir/bin/tmux" list-windows -a -F '#{session_name}:#{window_name}')
  [ "$endpoint_state" = firstmate:sentinel ] || {
    printf '%s refusal left unexpected endpoint(s): %s\n' "$name" "$endpoint_state" >&2
    exit 1
  }
  {
    printf '=== %s REFUSAL ===\n' "$name"
    cat "$LAB/$name.output.txt"
    printf '%s\n' 'before:'
    cat "$LAB/$name.before.txt"
    printf '%s\n' 'after:'
    cat "$LAB/$name.after.txt"
    printf 'replacement_endpoint=absent; original_fixture_window=%s\n' "$endpoint_state"
  } > "$LAB/$name-evidence.txt"
}

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME='Live Validation' GIT_AUTHOR_EMAIL='live-validation@example.invalid'
export GIT_COMMITTER_NAME='Live Validation' GIT_COMMITTER_EMAIL='live-validation@example.invalid'
mkdir -p "$LAB/tmux-sockets"

success="$LAB/success"
socket_success="$SOCKET_TAG-a"
setup_common "$success" "$socket_success"
trap '"$success/bin/tmux" kill-server >/dev/null 2>&1 || true; if [ -d "$LAB/adversary/bin" ]; then "$LAB/adversary/bin/tmux" kill-server >/dev/null 2>&1 || true; fi; if [ -d "$LAB/conflicting-identity/bin" ]; then "$LAB/conflicting-identity/bin/tmux" kill-server >/dev/null 2>&1 || true; fi; if [ -d "$LAB/wrong-confirmation/bin" ]; then "$LAB/wrong-confirmation/bin/tmux" kill-server >/dev/null 2>&1 || true; fi' EXIT
"$success/bin/tmux" new-session -d -s firstmate -n sentinel -c "$success/firstmate" /bin/sleep 180
head_before=$(git -C "$success/wt" rev-parse HEAD)
tracked_before=$(cat "$success/wt/README.md")
untracked_before=$(cat "$success/wt/untracked-handoff.txt")
run_handoff "$success" 'STOP paseo-backend-adapter' 'TERMINAL paseo-backend-adapter' "$LAB/success-output.txt" || {
  rc=$?
  cat "$LAB/success-output.txt"
  exit "$rc"
}
window=$(sed -n 's/^window=//p' "$success/home/state/paseo-backend-adapter.meta")
new_session=${window%%:*}
[ "$new_session" != firstmate ]
[ "$(git -C "$success/wt" rev-parse HEAD)" = "$head_before" ]
[ "$(cat "$success/wt/README.md")" = "$tracked_before" ]
[ "$(cat "$success/wt/untracked-handoff.txt")" = "$untracked_before" ]
[ "$(sed -n 's/^phase=//p' "$success/home/state/paseo-backend-adapter.control-relaunch")" = complete ]
grep -q '^handoff_worker_attested=stopped$' "$success/home/state/paseo-backend-adapter.control-relaunch"
grep -q '^handoff_run_attested=terminal$' "$success/home/state/paseo-backend-adapter.control-relaunch"
grep -q 'Continue in this exact local copy' "$success/home/data/paseo-backend-adapter/brief.md"
window_state=$("$success/bin/tmux" list-windows -t "$new_session" -F '#{window_name} #{pane_current_path} #{pane_current_command}')
case "$window_state" in
  "fm-paseo-backend-adapter $success/wt "*) ;;
  *) printf 'unexpected replacement pane state: %s\n' "$window_state" >&2; exit 1 ;;
esac
{
  printf '%s\n' '=== LIVE HANDOFF ==='
  cat "$LAB/success-output.txt"
  printf 'replacement_recorded_endpoint=%s\n' "$window"
  printf 'replacement_window_state=%s\n' "$window_state"
  printf 'recorded_branch=%s\n' "$(git -C "$success/wt" branch --show-current)"
  printf 'recorded_HEAD=%s\n' "$(git -C "$success/wt" rev-parse HEAD)"
  printf '%s\n' 'preserved_worktree_status:'
  git -C "$success/wt" status --short
  printf 'journal_phase=%s\n' "$(sed -n 's/^phase=//p' "$success/home/state/paseo-backend-adapter.control-relaunch")"
  printf 'journal_worker_attestation=%s\n' "$(sed -n 's/^handoff_worker_attested=//p' "$success/home/state/paseo-backend-adapter.control-relaunch")"
  printf 'journal_run_attestation=%s\n' "$(sed -n 's/^handoff_run_attested=//p' "$success/home/state/paseo-backend-adapter.control-relaunch")"
  if [ -f "$LAB/codex-invocations.log" ]; then
    printf 'replacement_harness_invocation=%s\n' "$(cat "$LAB/codex-invocations.log")"
  else
    printf 'replacement_harness_executable=%s\n' "$(command -v codex)"
  fi
} > "$LAB/success-evidence.txt"
"$success/bin/tmux" kill-server >/dev/null

adversary="$LAB/adversary"
socket_adversary="$SOCKET_TAG-b"
setup_common "$adversary" "$socket_adversary"
if [ "${REAL_CODEX:-0}" = 1 ]; then
  "$adversary/bin/tmux" new-session -d -s firstmate -n fm-paseo-backend-adapter \
    -c "$adversary/wt" "$(command -v codex)"
else
  if [ ! -x "$adversary/bin/codex" ]; then
    cat > "$adversary/bin/codex" <<'EOF'
#!/usr/bin/env bash
exec -a codex /bin/sleep 180
EOF
    chmod +x "$adversary/bin/codex"
  fi
  "$adversary/bin/tmux" new-session -d -s firstmate -n fm-paseo-backend-adapter \
    -c "$adversary/wt" "$adversary/bin/codex"
fi
# Wait for the recorded legacy pane to be positively classified as live before
# attempting the attested handoff against it.
for _ in $(seq 1 40); do
  state=$("$adversary/bin/tmux" display-message -p -t firstmate:fm-paseo-backend-adapter '#{pane_current_command}')
  [ "$state" = codex ] && break
  sleep 0.1
done
[ "$state" = codex ] || {
  printf 'the old endpoint did not remain a live Codex process: %s\n' "$state" >&2
  exit 1
}
meta_before=$(cat "$adversary/home/state/paseo-backend-adapter.meta")
brief_before=$(cat "$adversary/home/data/paseo-backend-adapter/brief.md")
head_before=$(git -C "$adversary/wt" rev-parse HEAD)
tracked_before=$(cat "$adversary/wt/README.md")
untracked_before=$(cat "$adversary/wt/untracked-handoff.txt")
if run_handoff "$adversary" 'STOP paseo-backend-adapter' 'TERMINAL paseo-backend-adapter' "$LAB/adversary-output.txt"; then
  printf '%s\n' 'unsafe: handoff unexpectedly accepted the live old endpoint' >&2
  exit 1
fi
[ "$(cat "$adversary/home/state/paseo-backend-adapter.meta")" = "$meta_before" ]
[ "$(cat "$adversary/home/data/paseo-backend-adapter/brief.md")" = "$brief_before" ]
[ "$(git -C "$adversary/wt" rev-parse HEAD)" = "$head_before" ]
[ "$(cat "$adversary/wt/README.md")" = "$tracked_before" ]
[ "$(cat "$adversary/wt/untracked-handoff.txt")" = "$untracked_before" ]
sessions=$("$adversary/bin/tmux" list-sessions -F '#{session_name}')
[ "$sessions" = firstmate ]
{
  printf '%s\n' '=== LIVE ADVERSARIAL CHECK ==='
  cat "$LAB/adversary-output.txt"
  printf 'old_endpoint_state=%s\n' "$state"
  printf 'sessions_after_refusal=%s\n' "$sessions"
  printf '%s\n' 'task_record=unchanged' 'brief=unchanged' 'worktree_HEAD=unchanged' 'tracked_and_untracked_changes=unchanged'
} > "$LAB/adversary-evidence.txt"
"$adversary/bin/tmux" kill-server >/dev/null

conflicting_identity="$LAB/conflicting-identity"
socket_conflict="$SOCKET_TAG-c"
setup_common "$conflicting_identity" "$socket_conflict"
"$conflicting_identity/bin/tmux" new-session -d -s firstmate -n sentinel \
  -c "$conflicting_identity/firstmate" /bin/sleep 180
assert_refusal_unchanged "$conflicting_identity" conflicting-identity \
  'STOP paseo-backend-adapter' 'TERMINAL paseo-backend-adapter' \
  "$conflicting_identity/firstmate" \
  '--expect-worktree must match the exact path recorded for the local copy'
"$conflicting_identity/bin/tmux" kill-server >/dev/null

wrong_confirmation="$LAB/wrong-confirmation"
socket_wrong_confirmation="$SOCKET_TAG-d"
setup_common "$wrong_confirmation" "$socket_wrong_confirmation"
"$wrong_confirmation/bin/tmux" new-session -d -s firstmate -n sentinel \
  -c "$wrong_confirmation/firstmate" /bin/sleep 180
assert_refusal_unchanged "$wrong_confirmation" wrong-confirmation \
  'STOP paseo-backend-adapter' 'TERMINAL paseo-backend-adapter-typo' \
  "$wrong_confirmation/wt" 'handoff confirmation did not match; no task files or endpoint were changed'
"$wrong_confirmation/bin/tmux" kill-server >/dev/null

cat "$LAB/success-evidence.txt" "$LAB/adversary-evidence.txt" \
  "$LAB/conflicting-identity-evidence.txt" "$LAB/wrong-confirmation-evidence.txt" \
  > "$LAB/live-evidence.txt"
cat "$LAB/live-evidence.txt"
