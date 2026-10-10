#!/usr/bin/env bash
# fm-gate-ab.sh behavior: arm assignment, the manual-arm log, the helper's
# refusal and logging while the experiment is enabled, and the per-arm report
# computed from a fixture decision log, no-mistakes state database, Claude
# transcript, and worker status lines.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AB="$ROOT/bin/fm-gate-ab.sh"
HELPER="$ROOT/bin/fm-gate-decide.sh"
TMP_ROOT=$(fm_test_tmproot fm-gate-ab)

ab() {  # <args...>: run against $HOME_DIR
  env FM_HOME="$HOME_DIR" NM_HOME="$HOME_DIR/nm" FM_GATE_AB_NOW=200000 "$AB" "$@"
}

new_home() {  # <name>
  HOME_DIR="$TMP_ROOT/$1/home"
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config" "$HOME_DIR/nm"
}

run_for_arm() {  # <arm> -> a run id whose review key is assigned to <arm>
  local n=0 run
  while :; do
    run="01ABRUN$(printf '%019d' "$n")"
    [ "$(ab assign "nm-$run-review")" = "$1" ] && { printf '%s\n' "$run"; return 0; }
    n=$((n + 1))
  done
}

test_assign() {
  local n arm helpers=0 manuals=0 a b
  new_home assign
  assert_equals helper "$(ab assign nm-RUN1-review)" "no experiment: the helper is the default"
  touch "$HOME_DIR/config/gate-ab"
  for n in $(seq 1 40); do
    a=$(ab assign "nm-RUN$n-review"); b=$(ab assign "nm-RUN$n-review")
    assert_equals "$a" "$b" "an arm is stable for its key"
    case "$a" in helper) helpers=$((helpers + 1)) ;; manual) manuals=$((manuals + 1)) ;; *) fail "bad arm '$a'" ;; esac
  done
  [ "$helpers" -gt 5 ] && [ "$manuals" -gt 5 ] || fail "the flip must reach both arms ($helpers/$manuals)"
  ab assign 'not a key' >/dev/null 2>&1; expect_code 2 $? "a non-key is a usage error"
  arm=$(env -u FM_HOME "$AB" assign nm-RUN1-review 2>&1); expect_code 2 $? "an implicit home is refused"
  pass "fm-gate-ab: assignment is stable, balanced, and off without the flag"
}

test_log_manual() {
  local out
  new_home log
  out=$(ab log nm-RUNX-review --task t1 --round 2 --fix A-1 --no-change A-2,A-3 2>&1); expect_code 1 $? "log needs the experiment enabled"
  assert_absent "$HOME_DIR/data/gate-ab.jsonl" "nothing is logged while disabled"
  touch "$HOME_DIR/config/gate-ab"
  ab log nm-RUNX-review --task t1 --round 2 --fix A-1 --no-change A-2,A-3 >/dev/null || fail "log"
  ab log nm-RUNX-review --task t1 --round 2 --fix A-1,A-1 >/dev/null 2>&1; expect_code 2 $? "a repeated id is refused"
  python3 -I - "$HOME_DIR/data/gate-ab.jsonl" <<'PY' || fail "the manual log line is wrong"
import json, sys
recs = [json.loads(l) for l in open(sys.argv[1])]
assert len(recs) == 1
r = recs[0]
assert r["arm"] == "manual" and r["run"] == "RUNX" and r["step"] == "review" and r["round"] == 2
assert r["task"] == "t1" and r["at"] == 200000 and "digest" not in r
assert r["findings"] == [{"id": "A-1", "action": "fix"}, {"id": "A-2", "action": "no-change"},
                         {"id": "A-3", "action": "no-change"}]
PY
  pass "fm-gate-ab: log appends one manual-arm record and refuses a disabled or malformed call"
}

make_fakebin() {  # <dir>
  local fb
  fb=$(fm_fakebin "$1")
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "axi status") cat "$FM_FAKE_NM_DIR/status.toon" ;;
  "axi") cat "$FM_FAKE_NM_DIR/overview.toon" ;;
esac
SH
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n' ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n' ;;
  list-windows) printf 'fm-t1\n' ;;
esac
exit 0
SH
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fb/sleep"
  chmod +x "$fb/no-mistakes" "$fb/tmux" "$fb/sleep"
  printf '%s\n' "$fb"
}

# gate_world <run>: task t1 parked at review round 1 with finding QD-1.
gate_world() {
  local base="$HOME_DIR/.." run=$1 sha
  fm_git_worktree "$base/repo" "$base/wt" fm/t1 >/dev/null 2>&1 || fail "fixture worktree"
  sha=$(git -C "$base/wt" rev-parse HEAD)
  FB=$(make_fakebin "$base")
  printf 'needs-decision [key=nm-%s-review]: ask-user findings=QD-1 file=x\n' "$run" > "$HOME_DIR/state/t1.status"
  fm_write_meta "$HOME_DIR/state/t1.meta" "window=sess:fm-t1" "kind=ship" "worktree=$base/wt" "branch=fm/t1"
  cat > "$HOME_DIR/nm/overview.toon" <<EOF
repo: $base/repo
current_branch: fm/t1
count: 1 of 1 total
runs[1]{id,branch,status,head,pr}:
  "$run",fm/t1,running,${sha:0:8},""
EOF
  cat > "$HOME_DIR/nm/status.toon" <<EOF
run:
  id: "$run"
  branch: fm/t1
  status: running
  awaiting_agent: parked 2m
  head: ${sha:0:8}
  head_sha: $sha
gate:
  step: review
  status: awaiting_approval
  findings[1]{id,severity,file,action,description}:
    QD-1,warning,app.py,ask-user,"Fix this"
help[1]: Run \`no-mistakes axi respond --action approve\` to accept this step and continue
EOF
  python3 -I - "$HOME_DIR/nm/state.sqlite" "$run" <<'PY'
import json, sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.execute("CREATE TABLE step_results (id TEXT, run_id TEXT, step_name TEXT)")
db.execute("CREATE TABLE step_rounds (step_result_id, round, findings_json, selected_finding_ids, fix_summary, reviewed_head_sha, starting_head_sha)")
db.execute("INSERT INTO step_results VALUES ('sr1', ?, 'review')", (sys.argv[2],))
db.execute("INSERT INTO step_rounds VALUES ('sr1', 1, ?, NULL, NULL, ?, ?)",
           (json.dumps({"findings": [{"id": "QD-1", "action": "ask-user"}]}), "a" * 40, "a" * 40))
db.commit()
PY
}

decide() {  # <args...>
  env PATH="$FB:$PATH" FM_HOME="$HOME_DIR" NM_HOME="$HOME_DIR/nm" FM_FAKE_NM_DIR="$HOME_DIR/nm" \
    FM_SEND_SETTLE=0 "$HELPER" t1 "$@"
}

test_helper_respects_arm_and_logs() {
  local run out digest rc
  new_home helper-arm
  touch "$HOME_DIR/config/gate-ab"
  run=$(run_for_arm manual)
  gate_world "$run"
  out=$(decide --fix QD-1 2>&1); rc=$?
  expect_code 1 "$rc" "a manual-arm key is refused by the helper"
  assert_contains "$out" "assigned to the manual arm" "the refusal names the arm"
  assert_absent "$HOME_DIR/state/t1.inbox" "nothing is sent for a manual-arm key"

  new_home helper-arm2
  touch "$HOME_DIR/config/gate-ab"
  run=$(run_for_arm helper)
  gate_world "$run"
  out=$(decide --fix QD-1 2>&1); digest=$(printf '%s\n' "$out" | sed -n 's/^digest: //p')
  out=$(decide --fix QD-1 --confirm "$digest" 2>&1); rc=$?
  expect_code 0 "$rc" "a helper-arm key sends: $out"
  python3 -I - "$HOME_DIR/data/gate-ab.jsonl" "$run" "$digest" <<'PY' || fail "the helper-arm line is wrong"
import json, sys
recs = [json.loads(l) for l in open(sys.argv[1])]
assert len(recs) == 1
r = recs[0]
assert r["arm"] == "helper" and r["run"] == sys.argv[2] and r["digest"] == sys.argv[3]
assert r["task"] == "t1" and r["step"] == "review" and r["round"] == 1
assert r["findings"] == [{"id": "QD-1", "action": "fix"}]
PY

  new_home helper-off
  touch "$HOME_DIR/config/gate-ab"
  run=$(run_for_arm manual)
  rm -f "$HOME_DIR/config/gate-ab"
  gate_world "$run"
  out=$(decide --fix QD-1 2>&1); digest=$(printf '%s\n' "$out" | sed -n 's/^digest: //p')
  decide --fix QD-1 --confirm "$digest" >/dev/null 2>&1 || fail "the helper is the default without the experiment"
  assert_absent "$HOME_DIR/data/gate-ab.jsonl" "nothing is logged outside the experiment"
  pass "fm-gate-ab: the helper honors the assigned arm, logs its own arm, and is untouched when disabled"
}

make_report_db() {  # <drop-column>
  python3 -I - "$HOME_DIR/nm/state.sqlite" "${1:-}" <<'PY'
import sqlite3, sys
path, drop = sys.argv[1:]
db = sqlite3.connect(path)
db.execute("CREATE TABLE runs (id TEXT)")
db.execute("CREATE TABLE step_results (id TEXT, run_id TEXT, step_name TEXT, completed_at INTEGER)")
cols = [c for c in ["step_result_id", "round", "selected_finding_ids", "user_findings_json",
                    "selection_source", "reviewed_head_sha", "created_at"] if c != drop]
db.execute("CREATE TABLE step_rounds (%s)" % ", ".join(cols))
for sid, run, done in [("sH", "RUNH", 100500), ("sM", "RUNM", 100700), ("sZ", "RUNZ", 50900), ("sY", "RUNY", 200900)]:
    db.execute("INSERT INTO step_results VALUES (?, ?, 'review', ?)", (sid, run, done))
rows = [
    ("sH", 1, '["A-1"]', "[]", "user", "a", 100100), ("sH", 2, None, None, None, "b", 100400),
    ("sM", 1, '["B-1","B-2"]', "[]", "user", "a", 100100), ("sM", 2, '["B-1"]', "[]", "user", "b", 100300),
    ("sM", 3, None, None, None, "c", 100600),
    ("sZ", 1, '["C-1"]', "[]", "user", "a", 50000), ("sZ", 2, None, None, None, "b", 50500),
    ("sY", 1, '["D-1"]', "[]", "user", "a", 200000),
]
vals = {"step_result_id": 0, "round": 1, "selected_finding_ids": 2, "user_findings_json": 3,
        "selection_source": 4, "reviewed_head_sha": 5, "created_at": 6}
for r in rows:
    db.execute("INSERT INTO step_rounds (%s) VALUES (%s)" % (", ".join(cols), ", ".join("?" * len(cols))),
               [r[vals[c]] for c in cols])
db.commit()
PY
}

make_report_world() {
  local tdir="$HOME_DIR/transcripts"
  mkdir -p "$tdir"
  make_report_db
  printf '%s\n' \
    '{"schema":"fm-gate-ab.v1","key":"nm-RUNH-review","arm":"helper","task":"t1","run":"RUNH","step":"review","round":1,"findings":[{"id":"A-1","action":"fix"}],"digest":"deadbeefdeadbeef","at":100160}' \
    '{"schema":"fm-gate-ab.v1","key":"nm-RUNM-review","arm":"manual","task":"t2","run":"RUNM","step":"review","round":1,"findings":[{"id":"B-1","action":"fix"},{"id":"B-2","action":"no-change"}],"at":100250}' \
    > "$HOME_DIR/data/gate-ab.jsonl"
  printf 'blocked [at=100200]: respond rejected: unknown flag --finding\n' > "$HOME_DIR/state/t2.status"
  printf 'needs-decision [at=50010] [key=nm-RUNZ-review]: ask-user findings=C-1\n' > "$HOME_DIR/state/t3.status"
  python3 -I - "$tdir/s1.jsonl" <<'PY'
import json, sys
def asst(mid, out, inp, cc, cr, cmd=None):
    content = [{"type": "text", "text": "x"}]
    if cmd:
        content.append({"type": "tool_use", "id": "t" + mid, "name": "Bash", "input": {"command": cmd}})
    return {"type": "assistant", "message": {"id": mid, "role": "assistant", "content": content,
            "usage": {"output_tokens": out, "input_tokens": inp, "cache_creation_input_tokens": cc,
                      "cache_read_input_tokens": cr}}}
res = {"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "x", "content": "ok"}]}}
def prompt(t):
    return {"type": "user", "message": {"role": "user", "content": t}}
lines = [
    prompt("wake one"),
    asst("m1", 100, 10, 50, 9999, "FM_HOME=/h bin/fm-gate-decide.sh t1 --fix A-1 --confirm deadbeefdeadbeef"),
    res, asst("m2", 30, 5, 0, 9999),
    prompt("wake two"),
    asst("m3", 40, 7, 0, 5, "bin/fm-send.sh t2 --resolve-key nm-RUNM-review 'fix B-1'"),
]
open(sys.argv[1], "w").write("\n".join(json.dumps(l) for l in lines) + "\n")
PY
}

test_report() {
  local out
  new_home report
  touch "$HOME_DIR/config/gate-ab"
  make_report_world
  out=$(ab report --since 100000 --baseline-days 1 --transcripts "$HOME_DIR/transcripts" 2>&1); expect_code 0 $? "report runs"
  printf '%s\n' "$out" | grep -E '^helper +1 +130 \(n=1\) +195 \(n=1\) +0\.00 \(n=1\) +0\.00 \(n=1\) +0\.00 \(n=1\) +60 \(n=1\) +400 \(n=1\)$' >/dev/null \
    || fail "helper row is wrong: $out"
  printf '%s\n' "$out" | grep -E '^manual +1 +40 \(n=1\) +47 \(n=1\) +1\.00 \(n=1\) +1\.00 \(n=1\) +1\.00 \(n=1\) +150 \(n=1\) +600 \(n=1\)$' >/dev/null \
    || fail "manual row is wrong: $out"
  printf '%s\n' "$out" | grep -E '^baseline +1 +- +- +0\.00 \(n=1\) +0\.00 \(n=1\) +0\.00 \(n=1\) +- +900 \(n=1\)$' >/dev/null \
    || fail "baseline row is wrong: $out"
  assert_contains "$out" "no significance is claimed" "the report states its limits"
  pass "fm-gate-ab: report computes per-arm measures and a baseline with sample sizes"
}

test_report_refuses_schema_drift() {
  local out rc
  new_home drift
  touch "$HOME_DIR/config/gate-ab"
  make_report_world
  rm -f "$HOME_DIR/nm/state.sqlite"
  make_report_db selection_source
  out=$(ab report --since 100000 --transcripts "$HOME_DIR/transcripts" 2>&1); rc=$?
  expect_code 1 "$rc" "schema drift is refused"
  assert_contains "$out" "step_rounds lacks selection_source" "the refusal names the missing column"
  rm -f "$HOME_DIR/nm/state.sqlite"
  out=$(ab report --since 100000 2>&1); expect_code 1 $? "a missing database is refused"
  pass "fm-gate-ab: report refuses a drifted or missing state database"
}

test_assign
test_log_manual
test_helper_respects_arm_and_logs
test_report
test_report_refuses_schema_drift
