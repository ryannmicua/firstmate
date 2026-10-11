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
    BASH_ENV="${FM_AB_BASH_ENV:-}" FM_SEND_SETTLE=0 "$HELPER" t1 "$@"
}

test_helper_respects_arm_and_logs() {
  local run out digest rc
  FM_AB_BASH_ENV="$TMP_ROOT/no-mapfile"
  printf 'enable -n mapfile 2>/dev/null || :\n' > "$FM_AB_BASH_ENV"
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

  new_home helper-partial
  touch "$HOME_DIR/config/gate-ab"
  run=$(run_for_arm helper)
  gate_world "$run"
  cat > "$FB/tr" <<'SH'
#!/usr/bin/env bash
if [ -f "$FM_HOME/state/t1.inbox/001.msg" ] && [ -f "$FM_HOME/state/t1.status" ]; then
  mv "$FM_HOME/state/t1.status" "$FM_HOME/state/t1.status.saved"
  mkdir "$FM_HOME/state/t1.status"
fi
command -p tr "$@"
SH
  chmod +x "$FB/tr"
  out=$(decide --fix QD-1 2>&1); digest=$(printf '%s\n' "$out" | sed -n 's/^digest: //p')
  out=$(decide --fix QD-1 --confirm "$digest" 2>&1); rc=$?
  expect_code 5 "$rc" "an enqueued decision with failed closure exits 5: $out"
  python3 -I - "$HOME_DIR/data/gate-ab.jsonl" "$HOME_DIR/data/t1/gate-decisions.jsonl" <<'PY' || fail "partial delivery lost its A/B record"
import json, sys
ab = [json.loads(l) for l in open(sys.argv[1])]
records = [json.loads(l) for l in open(sys.argv[2])]
assert len(ab) == len(records) == 1
assert records[0]["delivery"] == "delivered-unconfirmed"
assert ab[0]["digest"] == records[0]["digest"]
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
  printf 'needs-decision [key=nm-RUNH-review] [at=100110]: ask-user findings=A-1\n' > "$HOME_DIR/state/t1.status"
  printf '%s\n' \
    'needs-decision [at=100110] [key=nm-RUNM-review]: ask-user findings=B-1,B-2' \
    'blocked [key=nm-RUNM-review] [corr=abcd] [at=100200]: respond rejected: unknown flag --finding' \
    > "$HOME_DIR/state/t2.status"
  printf 'needs-decision [at=50010] [key=nm-RUNZ-review]: ask-user findings=C-1\n' > "$HOME_DIR/state/t3.status"
  python3 -I - "$tdir/s1.jsonl" <<'PY'
import datetime, json, sys
def asst(mid, out, inp, cc, cr, cmd=None, at=None):
    content = [{"type": "text", "text": "x"}]
    if cmd:
        content.append({"type": "tool_use", "id": "t" + mid, "name": "Bash", "input": {"command": cmd}})
    return {"type": "assistant", "timestamp": datetime.datetime.fromtimestamp(at, datetime.timezone.utc).isoformat() if at else None,
            "message": {"id": mid, "role": "assistant", "content": content,
            "usage": {"output_tokens": out, "input_tokens": inp, "cache_creation_input_tokens": cc,
                      "cache_read_input_tokens": cr}}}
def result(mid):
    return {"type": "user", "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "t" + mid, "content": "ok"}]}}
def prompt(t):
    return {"type": "user", "message": {"role": "user", "content": t}}
lines = [
    prompt("wake one"),
    asst("m1", 100, 10, 50, 9999, "FM_HOME=/h bin/fm-gate-decide.sh t1 --fix A-1 --confirm deadbeefdeadbeef", 100150),
    result("m1"), asst("m2", 30, 5, 0, 9999),
    prompt("wake two"),
    asst("m3", 40, 7, 0, 5, "bin/fm-send.sh t2 --resolve-key nm-RUNM-review 'fix B-1'", 100240),
    result("m3"),
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
  printf '%s\n' "$out" | grep -E '^helper +1 +130 \(n=1\) +195 \(n=1\) +0\.00 \(n=1\) +0\.00 \(n=1\) +0\.00 \(n=1\) +390 \(n=1\)$' >/dev/null \
    || fail "helper row is wrong: $out"
  printf '%s\n' "$out" | grep -E '^manual +1 +40 \(n=1\) +47 \(n=1\) +1\.00 \(n=1\) +1\.00 \(n=1\) +1\.00 \(n=1\) +590 \(n=1\)$' >/dev/null \
    || fail "manual row is wrong: $out"
  printf '%s\n' "$out" | grep -E '^baseline +1 +- +- +0\.00 \(n=1\) +0\.00 \(n=1\) +0\.00 \(n=1\) +890 \(n=1\)$' >/dev/null \
    || fail "baseline row is wrong: $out"
  assert_contains "$out" "no significance is claimed" "the report states its limits"
  pass "fm-gate-ab: report computes per-arm measures and a baseline with sample sizes"
}

test_report_individual_deliveries() {
  local out
  new_home report-rounds
  make_report_world
  python3 -I - "$HOME_DIR" <<'PY' || fail "individual delivery fixtures"
import datetime, json, pathlib, sqlite3, sys
home = pathlib.Path(sys.argv[1])
with sqlite3.connect(home / "nm/state.sqlite") as db:
    db.execute("UPDATE step_rounds SET selected_finding_ids = '[\"C-1\"]', selection_source = 'user' WHERE step_result_id = 'sZ' AND round = 2")
    db.execute("INSERT INTO step_results VALUES ('sX', 'UNRELATED', 'review', 50900)")
    db.execute("INSERT INTO step_rounds VALUES ('sX', 1, '[\"X-1\"]', '[]', 'user', 'a', 50000)")
with (home / "data/gate-ab.jsonl").open("a") as fh:
    fh.write(json.dumps({"key": "nm-RUNM-review", "arm": "manual", "task": "t2", "run": "RUNM",
                         "step": "review", "round": 2, "at": 100450, "findings": [{"id": "B-1", "action": "fix"}]}) + "\n")
with (home / "state/t2.status").open("a") as fh:
    fh.write("needs-decision [key=nm-RUNM-review] [at=100310]: ask-user findings=B-1\n")
with (home / "state/t3.status").open("a") as fh:
    fh.write("needs-decision [key=nm-RUNZ-review] [at=50510]: ask-user findings=C-1\n")
def turn(mid, at, tokens, cmd, failed=False, text="ok"):
    return [
        {"type": "user", "message": {"content": "wake"}},
        {"type": "assistant", "timestamp": datetime.datetime.fromtimestamp(at, datetime.timezone.utc).isoformat(),
         "message": {"id": mid, "usage": {"output_tokens": tokens}, "content": [
             {"type": "tool_use", "id": mid, "input": {"command": cmd}}]}},
        {"type": "user", "message": {"content": [
            {"type": "tool_result", "tool_use_id": mid, "is_error": failed, "content": text}]}},
    ]
path = home / "transcripts/s1.jsonl"
entries = [json.loads(l) for l in path.read_text().splitlines()]
for e in entries:
    for b in (e.get("message") or {}).get("content") or []:
        if isinstance(b, dict) and b.get("tool_use_id") == "tm1":
            b.update(is_error=True, content="error: the decision is recorded as delivered-unconfirmed; do not resend")
        if isinstance(b, dict) and b.get("tool_use_id") == "tm3":
            b.update(is_error=True, content="error: the answer was delivered to sess:fm-t2, but the close for decision key(s) 'nm-RUNM-review' could not be appended to /h/state/t2.status. Close it manually - do not resend the answer.")
entries = turn("failed-helper", 100140, 900, "bin/fm-gate-decide.sh t1 --confirm deadbeefdeadbeef", True) + entries
entries += turn("failed-manual", 100435, 900, "bin/fm-send.sh t2 --resolve-key nm-RUNM-review 'fix B-1'", text="Exit code: 1")
entries += turn("manual-r2", 100440, 400, "bin/fm-send.sh t2 --resolve-key nm-RUNM-review 'fix B-1'", True,
                [{"type": "text", "text": "error: the answer was delivered to sess:fm-t2, but decision key 'nm-RUNM-review' is still open in /h/state/t2.status; it may have been reopened concurrently or the fold did not accept the close. Close it manually - do not resend the answer.\nExit code: 1"}])
entries += turn("baseline-r1", 50200, 100, "bin/fm-send.sh t3 --resolve-key nm-RUNZ-review 'fix C-1'", True,
                "error: the answer was delivered to sess:fm-t3, but this captain-held task could not be closed: nm-RUNZ-review. Close it with fm-captain-hold.sh answer - do not resend the answer.")
entries += turn("baseline-r2", 50700, 400, "bin/fm-send.sh t3 --resolve-key nm-RUNZ-review 'fix C-1'")
path.write_text("".join(json.dumps(e) + "\n" for e in entries))
PY
  out=$(ab report --since 100000 --baseline-days 1 --transcripts "$HOME_DIR/transcripts" 2>&1)
  expect_code 0 $? "individual delivery report runs: $out"
  python3 -I - "$out" <<'PY' || fail "decisions did not get their own delivered turns: $out"
import re, sys
rows = {r[0]: r[1:] for l in sys.argv[1].splitlines() if (r := re.split(r"  +", l)) and r[0] in ("helper", "manual", "baseline")}
assert rows["helper"][:3] == ["1", "130 (n=1)", "195 (n=1)"], rows
assert rows["manual"][:3] == ["2", "220 (n=2)", "224 (n=2)"], rows
assert rows["baseline"][:3] == ["2", "250 (n=2)", "250 (n=2)"], rows
assert rows["manual"][-1] == "490 (n=2)", rows
assert rows["baseline"][-1] == "640 (n=2)", rows
PY
  pass "fm-gate-ab: successive manual and baseline rounds use distinct turns and helper retries exclude failures"
}

test_report_missing_history() {
  local out
  new_home report-retired
  make_report_world
  rm "$HOME_DIR/state/t1.status" "$HOME_DIR/state/t2.status" "$HOME_DIR/state/t3.status"
  printf '%s\n' \
    '{"key":"nm-RUNZ-review","arm":"manual","task":"t3","run":"RUNZ","step":"review","round":1,"at":50200,"findings":[{"id":"C-1","action":"fix"}]}' \
    >> "$HOME_DIR/data/gate-ab.jsonl"
  out=$(ab report --since 100000 --baseline-days 1 --transcripts "$HOME_DIR/transcripts" 2>&1)
  expect_code 0 $? "retired task report runs: $out"
  python3 -I - "$out" <<'PY' || fail "missing history was reported as zero: $out"
import re, sys
rows = {r[0]: r[1:] for l in sys.argv[1].splitlines() if (r := re.split(r"  +", l)) and r[0] in ("helper", "manual", "baseline")}
assert rows["baseline"][0] == "1", rows
for row in rows.values():
    assert row[-2:] == ["-", "-"], rows
PY
  pass "fm-gate-ab: retained decisions attribute retired tasks while missing status measures stay unavailable"
}

test_report_unknown_timestamps() {
  local out
  new_home report-unknown-time
  make_report_world
  printf '%s\n' \
    'needs-decision [key=nm-RUNH-review] [at=0100110]: ask-user findings=A-1' \
    'needs-decision [at=100110] [key=nm-RUNH-review] [at=100120]: ask-user findings=A-1' \
    'needs-decision [key=nm-RUNH-review]: ask-user findings=A-1 [at=100110]' \
    > "$HOME_DIR/state/t1.status"
  printf 'blocked [key=nm-RUNM-review] [at=0100200]: respond rejected\n' >> "$HOME_DIR/state/t2.status"
  out=$(ab report --since 100000 --baseline-days 1 --transcripts "$HOME_DIR/transcripts" 2>&1)
  expect_code 0 $? "unknown timestamp report runs: $out"
  python3 -I - "$out" <<'PY' || fail "noncanonical timestamps were accepted: $out"
import re, sys
rows = {r[0]: r[1:] for l in sys.argv[1].splitlines() if (r := re.split(r"  +", l)) and r[0] in ("helper", "manual", "baseline")}
assert rows["helper"][-1] == "-", rows
assert rows["manual"][-2] == "-", rows
PY
  pass "fm-gate-ab: malformed, duplicated and note-only timestamps leave measures unavailable"
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
test_report_individual_deliveries
test_report_missing_history
test_report_unknown_timestamps
test_report_refuses_schema_drift
