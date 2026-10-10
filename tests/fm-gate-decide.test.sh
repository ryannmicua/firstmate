#!/usr/bin/env bash
# fm-gate-decide.sh behavior: resolving a task's parked no-mistakes gate,
# validating firstmate's per-finding decision, annotating carried-over
# findings, composing an argument-safe respond command, and sending the steer
# through the real fm-send with --resolve-key.
#
# A fake `no-mistakes` serves fixture `axi status` and `axi` overview TOON and
# records any other invocation, so every case can assert the helper never runs
# `respond` itself. Round history lives in a fixture SQLite database at the
# path the real CLI would use (NM_HOME/state.sqlite).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HELPER="$ROOT/bin/fm-gate-decide.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-gate-decide)
RUN=01TESTRUN0000000000000000A

make_fakebin() {  # <dir> -> echoes fakebin
  local fb
  fb=$(fm_fakebin "$1")
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "axi status")
    if [ -f "$FM_FAKE_NM_DIR/change-mode" ]; then
      count=$(cat "$FM_FAKE_NM_DIR/status-count" 2>/dev/null || printf 0)
      count=$((count + 1))
      printf '%s' "$count" > "$FM_FAKE_NM_DIR/status-count"
      if [ "$count" = 2 ]; then
        python3 -I - "$FM_FAKE_NM_DIR" <<'PY'
import json, sqlite3, sys
from pathlib import Path
root = Path(sys.argv[1])
mode = (root / "change-mode").read_text()
p = root / "status.toon"
s = p.read_text()
if mode == "run":
    s = s.replace("01TESTRUN0000000000000000A", "01TESTRUN0000000000000000B")
elif mode == "step":
    s = s.replace("step: review", "step: test")
elif mode == "parked":
    s = s.replace("awaiting_agent: parked 2m", "awaiting_agent: running")
    s = s.split("gate:", 1)[0]
elif mode == "head":
    s += "branch_sync:\n  pipeline:\n    current_head: " + "c" * 40 + "\n"
elif mode in ("round", "findings"):
    with sqlite3.connect(root / "state.sqlite") as db:
        if mode == "round":
            db.execute("UPDATE step_rounds SET round = 3 WHERE round = 2")
        else:
            db.execute("UPDATE step_rounds SET findings_json = ? WHERE round = 2",
                       (json.dumps({"findings": [{"id": "QD-8"}, {"id": "QD-11"}, {"id": "QD-13"}]}),))
            s = s.replace("QD-12,info", "QD-13,info")
p.write_text(s)
PY
      fi
    fi
    cat "$FM_FAKE_NM_DIR/status.toon" ;;
  "axi") cat "$FM_FAKE_NM_DIR/overview.toon" ;;
  *)
    printf '%s\0' "$@" >> "$FM_FAKE_NM_DIR/other-calls"
    printf 'call\n' >> "$FM_FAKE_NM_DIR/other-calls.count" ;;
esac
SH
  chmod +x "$fb/no-mistakes"
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
  chmod +x "$fb/tmux"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fb/sleep"
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

# setup_world <name>: a home with task t1 on branch fm/t1 in its own worktree,
# a keyed open decision, fixture TOON, and an empty fixture database. Sets
# HOME_DIR, WT, NM_DIR, FB and HEAD_SHA.
setup_world() {
  local base="$TMP_ROOT/$1"
  if [ "${2:-}" = lab ]; then
    bash "$ROOT/bin/fm-lab-home.sh" create "$base/home" >/dev/null || fail "fixture lab home"
  fi
  mkdir -p "$base/home/state" "$base/home/data" "$base/nm"
  fm_git_worktree "$base/repo" "$base/wt" fm/t1 >/dev/null 2>&1 || fail "fixture worktree"
  HOME_DIR="$base/home"; WT="$base/wt"; NM_DIR="$base/nm"
  FB=$(make_fakebin "$base")
  HEAD_SHA=$(git -C "$WT" rev-parse HEAD)
  fm_write_meta "$HOME_DIR/state/t1.meta" "window=sess:fm-t1" "kind=ship" "worktree=$WT" "branch=fm/t1"
  printf 'needs-decision [key=nm-%s-review]: ask-user findings=QD-8,QD-11 file=x\n' "$RUN" > "$HOME_DIR/state/t1.status"
  cat > "$NM_DIR/overview.toon" <<EOF
repo: $base/repo
current_branch: fm/t1
count: 1 of 1 total
runs[1]{id,branch,status,head,pr}:
  "$RUN",fm/t1,running,${HEAD_SHA:0:8},""
EOF
  write_status review "$(printf '%s\n' \
    '    QD-8,warning,app.py,ask-user,"The --bind alias duplicates --host, remove it"' \
    '    QD-11,error,app.py,auto-fix,"Unchecked return value"' \
    '    QD-12,info,app.py,no-op,"Informational note"')" 3
  make_db
}

write_status() {  # <step> <rows> <count>
  cat > "$NM_DIR/status.toon" <<EOF
run:
  id: "$RUN"
  branch: fm/t1
  status: running
  awaiting_agent: parked 2m
  head: ${HEAD_SHA:0:8}
  head_sha: $HEAD_SHA
gate:
  step: $1
  status: awaiting_approval
  findings[$3]{id,severity,file,action,description}:
$2
help[1]: Run \`no-mistakes axi respond --action approve\` to accept this step and continue
EOF
}

# make_db [drop-column]: fixture state database with the review step's rounds.
# Round 1 raised QD-8 and selected it for a fix; round 2 (current) carries
# QD-8 forward beside the new QD-11 and QD-12.
make_db() {
  python3 -I - "$NM_DIR/state.sqlite" "$RUN" "${1:-}" <<'PY'
import json, sqlite3, sys
path, run, drop = sys.argv[1:]
db = sqlite3.connect(path)
db.execute("CREATE TABLE step_results (id TEXT, run_id TEXT, step_name TEXT)")
cols = ["step_result_id", "round", "findings_json", "selected_finding_ids", "fix_summary",
        "reviewed_head_sha", "starting_head_sha"]
cols = [c for c in cols if c != drop]
db.execute("CREATE TABLE step_rounds (%s)" % ", ".join(cols))
db.execute("INSERT INTO step_results VALUES ('sr1', ?, 'review')", (run,))
f = lambda *ids: json.dumps({"findings": [{"id": i, "action": "ask-user"} for i in ids]})
rows = [
    {"step_result_id": "sr1", "round": 1, "findings_json": f("QD-8"), "selected_finding_ids": '["QD-8"]',
     "fix_summary": None, "reviewed_head_sha": "a" * 40, "starting_head_sha": "a" * 40},
    {"step_result_id": "sr1", "round": 2, "findings_json": f("QD-8", "QD-11", "QD-12"),
     "selected_finding_ids": None, "fix_summary": "changes applied", "reviewed_head_sha": "b" * 40,
     "starting_head_sha": "a" * 40},
]
for r in rows:
    db.execute("INSERT INTO step_rounds (%s) VALUES (%s)" % (", ".join(cols), ", ".join("?" * len(cols))),
               [r[c] for c in cols])
db.commit()
PY
}

helper() {  # <args...>: run the helper against the current world
  env PATH="$FB:$PATH" FM_HOME="$HOME_DIR" NM_HOME="$NM_DIR" FM_FAKE_NM_DIR="$NM_DIR" \
    FM_SEND_SETTLE=0 "$HELPER" t1 "$@"
}

assert_no_respond() {
  assert_absent "$NM_DIR/other-calls" "the helper must never invoke no-mistakes beyond read-only status calls"
}

digest_of() {  # <preview-output>
  printf '%s\n' "$1" | sed -n 's/^digest: //p'
}

test_preview_is_read_only_and_annotates_carried_ids() {
  local out rc
  setup_world preview
  mkdir -p "$HOME_DIR/config"
  touch "$HOME_DIR/config/wait-no-turns"
  out=$(helper --fix QD-8,QD-11 --no-change QD-12 --instructions "Keep repeatable --host." 2>&1); rc=$?
  expect_code 0 "$rc" "a complete decision previews"
  assert_contains "$out" "Run exactly this command in your worktree, the way your brief describes driving the pipeline, without editing it:" \
    "the emitted fix steer defers to the foreground brief"
  assert_not_contains "$out" "backgrounded" "the emitted fix steer does not override the brief"
  assert_contains "$out" "no-mistakes axi respond --step review --action fix --findings QD-8,QD-11 --instructions '" \
    "the preview shows the exact respond command"
  assert_contains "$out" "- QD-8: in round 1; round 1 selected it for a fix; fix round 2 moved aaaaaaaaaaaa -> bbbbbbbbbbbb (changes applied)" \
    "a carried-over id is annotated with its earlier round and fix evidence"
  assert_contains "$out" "re-verify each at pipeline head ${HEAD_SHA:0:12}" "the annotation names the pipeline head"
  assert_not_contains "$out" "- QD-11: in round" "a first-seen id is not annotated as carried over"
  assert_contains "$out" "This answers decision key nm-$RUN-review." "the steer names the decision key"
  assert_contains "$out" "Never add --yes or -y." "the steer carries the standing etiquette"
  [ -n "$(digest_of "$out")" ] || fail "the preview prints a digest"
  assert_absent "$HOME_DIR/state/t1.inbox" "a preview sends nothing"
  assert_absent "$HOME_DIR/data/t1/gate-decisions.jsonl" "a preview records nothing"
  assert_no_respond
  pass "fm-gate-decide: preview is read-only and annotates carried-over findings"
}

test_confirm_sends_closes_and_records() {
  local out rc digest drained
  setup_world send
  out=$(helper --fix QD-11 --no-change QD-8,QD-12 --reason "already satisfied at head" 2>&1)
  digest=$(digest_of "$out")
  out=$(helper --fix QD-11 --no-change QD-8,QD-12 --reason "already satisfied at head" --confirm "$digest" 2>&1); rc=$?
  expect_code 0 "$rc" "a confirmed decision sends"
  assert_grep "--findings QD-11 --instructions" "$HOME_DIR/state/t1.inbox/001.msg" \
    "the steer reaches the worker's durable inbox"
  assert_grep "- QD-8: no change - already satisfied at head" "$HOME_DIR/state/t1.inbox/001.msg" \
    "an unselected finding is listed as left unchanged"
  drained=$(FM_STATE_OVERRIDE="$HOME_DIR/state" "$DRAIN" 2>/dev/null)
  assert_not_contains "$drained" "[key=nm-$RUN-review]" "the decision key closes at answer time"
  python3 -I - "$HOME_DIR/data/t1/gate-decisions.jsonl" "$RUN" <<'PY' || fail "the durable record is incomplete"
import json, sys
recs = [json.loads(l) for l in open(sys.argv[1])]
assert len(recs) == 1
r = recs[0]
assert r["schema"] == "fm-gate-decision.v1" and r["run"] == sys.argv[2] and r["step"] == "review" and r["round"] == 2
assert {d["id"]: d["action"] for d in r["decisions"]} == {"QD-11": "fix", "QD-8": "no-change", "QD-12": "no-change"}
assert r["respond"]["findings"] == ["QD-11"]
PY
  assert_no_respond
  pass "fm-gate-decide: --confirm sends through fm-send, closes the key, and records the decision"
}

signal_helper() {  # <signal> <args...>: run the helper with the gate signal set per invocation
  local signal=$1; shift
  case "$signal" in
    env|lab) NO_MISTAKES_GATE=1 helper "$@" ;;
    lab-override) NO_MISTAKES_GATE=1 FM_DATA_OVERRIDE="$HOME_DIR/data" helper "$@" ;;
    empty) NO_MISTAKES_GATE='' helper "$@" ;;
    *) helper "$@" ;;
  esac
}

test_gate_authority_before_recording() {
  local signal out digest rc caller status_before gate_repo gate_cwd v
  for signal in env empty path lab lab-override normal; do
    case "$signal" in
      lab*) setup_world "authority-$signal" lab ;;
      *) setup_world "authority-$signal" ;;
    esac
    caller=$WT
    if [ "$signal" = path ]; then
      gate_repo="$NM_DIR/.no-mistakes/repos/fixture.git"
      gate_cwd="$NM_DIR/gate-worktree"
      mkdir -p "$NM_DIR/.no-mistakes/repos"
      git clone -q --bare "$WT" "$gate_repo" || fail "fixture gate repo"
      git -C "$gate_repo" worktree add -q --detach "$gate_cwd" HEAD || fail "fixture gate checkout"
      caller=$gate_cwd
    fi
    status_before=$(cat "$HOME_DIR/state/t1.status")
    out=$(
      cd "$caller" || exit 1
      unset FM_GATE_REFUSE_BYPASS NO_MISTAKES_GATE
      while IFS= read -r v; do
        case "$v" in *_OVERRIDE) unset "$v" ;; esac
      done < <(compgen -A variable FM_)
      signal_helper "$signal" --fix QD-8,QD-11 --no-change QD-12
    ); rc=$?
    expect_code 0 "$rc" "$signal read-only preview remains available"
    digest=$(digest_of "$out")
    assert_absent "$HOME_DIR/data/t1" "$signal preview creates no decision directory"
    out=$(
      cd "$caller" || exit 1
      unset FM_GATE_REFUSE_BYPASS NO_MISTAKES_GATE
      while IFS= read -r v; do
        case "$v" in *_OVERRIDE) unset "$v" ;; esac
      done < <(compgen -A variable FM_)
      signal_helper "$signal" --fix QD-8,QD-11 --no-change QD-12 --confirm "$digest" 2>&1
    ); rc=$?
    case "$signal" in
      lab|normal)
        expect_code 0 "$rc" "$signal decision is authorized: $out"
        assert_present "$HOME_DIR/data/t1/gate-decisions.jsonl" "$signal decision is recorded"
        assert_present "$HOME_DIR/state/t1.inbox/001.msg" "$signal decision is delivered" ;;
      *)
        expect_code 3 "$rc" "$signal gate agent must refuse"
        assert_contains "$out" "gate" "$signal reports gate authority refusal"
        assert_absent "$HOME_DIR/data/t1" "$signal refusal precedes record directory creation"
        assert_absent "$HOME_DIR/state/t1.inbox" "$signal refusal precedes delivery"
        [ "$(cat "$HOME_DIR/state/t1.status")" = "$status_before" ] || fail "$signal refusal changed decision status" ;;
    esac
    assert_no_respond
  done
  pass "fm-gate-decide: authority refusal precedes home mutation and preserves marked labs"
}

test_refused_send_records_nothing() {
  local out digest rc
  setup_world failed-send
  : > "$HOME_DIR/state/t1.status"
  out=$(helper --fix QD-8,QD-11 --no-change QD-12); digest=$(digest_of "$out")
  out=$(helper --fix QD-8,QD-11 --no-change QD-12 --confirm "$digest" 2>&1); rc=$?
  expect_code 4 "$rc" "a send fm-send refuses (no open decision for the key) exits 4"
  assert_contains "$out" "a resend is safe" "a refusal before enqueue says a resend is safe"
  assert_absent "$HOME_DIR/data/t1/gate-decisions.jsonl" "a refused send records nothing"
  assert_absent "$HOME_DIR/state/t1.inbox" "a pre-delivery refusal sends nothing"
  pass "fm-gate-decide: a send refusal leaves no decision record"
}

test_refused_send_ignores_earlier_identical_steer() {
  local out digest rc steer
  setup_world earlier-steer
  : > "$HOME_DIR/state/t1.status"
  out=$(helper --fix QD-8,QD-11 --no-change QD-12); digest=$(digest_of "$out")
  steer=$(printf '%s\n' "$out" | sed -n '/^--- steer preview/,/^--- end of preview ---$/p' | sed '1d;$d')
  mkdir -p "$HOME_DIR/state/t1.inbox/handled"
  printf 'schema=fm-task-inbox.v1\nat=2026-01-01T00:00:00Z\n--\n%s' "$steer" > "$HOME_DIR/state/t1.inbox/handled/001.msg"
  out=$(helper --fix QD-8,QD-11 --no-change QD-12 --confirm "$digest" 2>&1); rc=$?
  expect_code 4 "$rc" "a refused send beside an earlier identical steer exits 4: $out"
  assert_contains "$out" "a resend is safe" "an earlier identical steer is not proof of this delivery"
  assert_absent "$HOME_DIR/data/t1/gate-decisions.jsonl" "a refused send beside an earlier identical steer records nothing"
  assert_absent "$HOME_DIR/state/t1.inbox/002.msg" "the refused send enqueues nothing"
  pass "fm-gate-decide: an earlier identical inbox steer never turns a refusal into a recorded delivery"
}

test_partial_delivery_preserves_decision() {
  local out digest rc
  setup_world partial-send
  cat > "$FB/tr" <<'SH'
#!/usr/bin/env bash
if [ -f "$FM_HOME/state/t1.inbox/001.msg" ] && [ -f "$FM_HOME/state/t1.status" ]; then
  mv "$FM_HOME/state/t1.status" "$FM_HOME/state/t1.status.saved"
  mkdir "$FM_HOME/state/t1.status"
fi
command -p tr "$@"
SH
  chmod +x "$FB/tr"
  out=$(helper --fix QD-8,QD-11 --no-change QD-12); digest=$(digest_of "$out")
  out=$(helper --fix QD-8,QD-11 --no-change QD-12 --confirm "$digest" 2>&1); rc=$?
  expect_code 5 "$rc" "a post-delivery closure failure exits 5"
  assert_contains "$out" "the answer was delivered" "the real send fails after enqueue"
  assert_contains "$out" "recorded as delivered-unconfirmed" "the enqueued steer is recorded as unconfirmed"
  assert_contains "$out" "do not resend" "the failure forbids a resend"
  [ -f "$HOME_DIR/state/t1.inbox/001.msg" ] || fail "the decision was delivered"
  assert_absent "$HOME_DIR/state/t1.inbox/002.msg" "the helper does not resend"
  python3 -I - "$HOME_DIR/data/t1/gate-decisions.jsonl" <<'PY' || fail "the delivered decision was lost"
import json, sys
records = [json.loads(line) for line in open(sys.argv[1])]
assert len(records) == 1
assert records[0]["respond"]["findings"] == ["QD-8", "QD-11"]
assert records[0]["delivery"] == "delivered-unconfirmed"
PY
  pass "fm-gate-decide: partial delivery retains the decision without inviting duplication"
}

test_final_verification_refuses_changes() {
  local axis out digest rc
  for axis in run step parked round findings head; do
    setup_world "final-$axis"
    out=$(helper --fix QD-8,QD-11 --no-change QD-12); digest=$(digest_of "$out")
    printf '%s' "$axis" > "$NM_DIR/change-mode"
    out=$(helper --fix QD-8,QD-11 --no-change QD-12 --confirm "$digest" 2>&1); rc=$?
    [ "$rc" -ne 0 ] || fail "a $axis change immediately before send must refuse: $out"
    assert_absent "$HOME_DIR/state/t1.inbox" "a $axis change sends nothing"
    assert_absent "$HOME_DIR/data/t1/gate-decisions.jsonl" "a $axis change records nothing"
    assert_no_respond
  done
  pass "fm-gate-decide: final verification refuses run, step, parked state, round, finding, and head changes"
}

test_later_round_reads_the_earlier_decision() {
  local out digest
  setup_world later
  out=$(helper --fix QD-8,QD-11 --no-change QD-12 --instructions "Drop the --bind alias.")
  digest=$(digest_of "$out")
  helper --fix QD-8,QD-11 --no-change QD-12 --instructions "Drop the --bind alias." --confirm "$digest" >/dev/null 2>&1 \
    || fail "the first decision should send"
  # The pipeline runs a fix round and parks again at round 3, still carrying QD-8.
  python3 -I - "$NM_DIR/state.sqlite" <<'PY'
import json, sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.execute("UPDATE step_rounds SET selected_finding_ids = '[\"QD-8\",\"QD-11\"]' WHERE round = 2")
db.execute("INSERT INTO step_rounds VALUES ('sr1', 3, ?, NULL, 'changes applied', ?, ?)",
           (json.dumps({"findings": [{"id": "QD-8"}, {"id": "QD-13"}]}), "c" * 40, "b" * 40))
db.commit()
PY
  write_status review "$(printf '%s\n' '    QD-8,warning,app.py,no-op,"The --bind alias duplicates --host"' \
    '    QD-13,error,app.py,ask-user,"New finding"')" 2
  printf 'needs-decision [key=nm-%s-review]: ask-user findings=QD-8,QD-13 file=x\n' "$RUN" >> "$HOME_DIR/state/t1.status"
  expect_refusal "carried no-op omission" "incomplete decision: no decision for QD-8" --fix QD-13
  out=$(helper --no-change QD-8 --reason "satisfied" --fix QD-13 2>&1) || fail "explicit no-op decision should preview"
  assert_contains "$out" "- QD-8 [no-op]: no change - satisfied" "the emitted steer retains the no-op decision"
  assert_contains "$out" "- QD-8: in rounds 1,2; round 1 selected it for a fix; fix round 2 moved" \
    "every earlier round is listed"
  assert_contains "$out" "round 2 selected it for a fix; fix round 3 moved bbbbbbbbbbbb -> cccccccccccc" \
    "the latest fix round's evidence is listed"
  assert_contains "$out" "round 2 firstmate decision at head ${HEAD_SHA:0:12}: fix; instructions: Drop the --bind alias." \
    "the earlier decision comes back from the durable record"
  digest=$(digest_of "$out")
  helper --no-change QD-8 --reason "satisfied" --fix QD-13 --confirm "$digest" >/dev/null 2>&1 \
    || fail "the explicit carried no-op decision should send"
  assert_grep "- QD-8 [no-op]: no change - satisfied" "$HOME_DIR/state/t1.inbox/002.msg" \
    "the delivered steer retains the carried no-op decision"
  assert_grep "round 2 firstmate decision at head ${HEAD_SHA:0:12}: fix" "$HOME_DIR/state/t1.inbox/002.msg" \
    "the delivered steer retains the earlier decision"
  python3 -I - "$HOME_DIR/data/t1/gate-decisions.jsonl" <<'PY' || fail "the no-op decision was not recorded"
import json, sys
records = [json.loads(line) for line in open(sys.argv[1])]
assert len(records) == 2
assert records[-1]["round"] == 3
assert {d["id"]: d["action"] for d in records[-1]["decisions"]} == {"QD-8": "no-change", "QD-13": "fix"}
PY
  assert_no_respond
  pass "fm-gate-decide: a later round reads back the earlier decision and fix evidence"
}

test_command_is_argument_safe() {
  local out cmd tricky got
  setup_world quoting
  tricky=$'Use it\'s "quoted" text; $(touch pwned) `id` \\ and\na second line'
  out=$(helper --fix QD-8,QD-11 --no-change QD-12 --instructions "$tricky" 2>&1)
  cmd=$(printf '%s\n' "$out" | sed -n '/^Run exactly this command/,/^Never add --yes/p' | sed '1d;$d')
  ( cd "$TMP_ROOT" && env PATH="$FB:$PATH" FM_FAKE_NM_DIR="$NM_DIR" bash -c "$cmd" ) \
    || fail "the composed command should run in a POSIX shell"
  assert_absent "$TMP_ROOT/pwned" "instruction text must never execute"
  got=$(python3 -I - "$NM_DIR/other-calls" <<'PY'
import sys
args = open(sys.argv[1], "rb").read().split(b"\0")[:-1]
print(args[args.index(b"--instructions") + 1].decode(), end="")
PY
)
  assert_contains "$got" "$tricky" "the instructions argument round-trips byte for byte"
  pass "fm-gate-decide: the respond command is argument-safe"
}

test_approve_only_maps_to_approve() {
  local out
  setup_world approve
  out=$(helper --approve QD-8,QD-11,QD-12 --reason "accepted by design" 2>&1)
  assert_contains "$out" "Run exactly this command in your worktree, the way your brief describes driving the pipeline, without editing it:" \
    "the emitted approval steer defers to the default brief"
  assert_not_contains "$out" "backgrounded" "the emitted approval steer does not prescribe an execution mode"
  assert_contains "$out" "no-mistakes axi respond --step review --action approve"$'\n' \
    "an all-approve review decision maps to a bare approve"
  assert_contains "$out" "(Context only: an approval sends no instructions to the fixer.)" \
    "carried-over context is marked context-only on approval"
  write_status test "$(printf '%s\n' '    T-1,error,app_test.py,ask-user,"Flaky test"')" 1
  python3 -I - "$NM_DIR/state.sqlite" <<'PY'
import json, sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.execute("INSERT INTO step_results VALUES ('sr2', (SELECT run_id FROM step_results LIMIT 1), 'test')")
db.execute("INSERT INTO step_rounds VALUES ('sr2', 1, ?, NULL, NULL, NULL, NULL)",
           (json.dumps({"findings": [{"id": "T-1"}]}),))
db.commit()
PY
  out=$(helper --approve T-1 --reason "known flake, tracked separately" 2>&1)
  assert_contains "$out" "--step test --action approve --reason 'T-1: known flake, tracked separately'" \
    "a test-step approval preserves the reason"
  pass "fm-gate-decide: approvals map to --action approve, with --reason only on the test step"
}

# The no-mistakes skill documents a scalar `gate: <step>` form whose findings
# table is a sibling of the gate line, with unquoted free-text descriptions.
test_scalar_gate_form() {
  local out
  setup_world scalar
  cat > "$NM_DIR/status.toon" <<EOF
run:
  id: "$RUN"
  branch: fm/t1
  status: running
  awaiting_agent: parked 1m
  head_sha: $HEAD_SHA
gate: review
note: Review auto-fix is disabled by default, so findings park.
findings[3]{id,severity,file,line,action,description}:
  QD-8,warning,app.py,,ask-user,The alias duplicates --host, and also --bind
  QD-11,error,app.py,12,auto-fix,Unchecked return value
  QD-12,info,app.py,,no-op,Informational
help[1]:
  Run \`no-mistakes axi respond --action approve\` to accept this step and continue
EOF
  out=$(helper --fix QD-11 --no-change QD-8,QD-12 2>&1) || fail "the scalar gate form should resolve: $out"
  assert_contains "$out" "--step review --action fix --findings QD-11" "the scalar form yields the step and ids"
  pass "fm-gate-decide: reads the scalar gate form with unquoted descriptions"
}

expect_refusal() {  # <label> <needle> <args...>
  local label=$1 needle=$2 out rc
  shift 2
  out=$(helper "$@" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "$label: expected a refusal"
  assert_contains "$out" "$needle" "$label"
}

test_no_op_requires_explicit_decisions() {
  local form out
  for form in block scalar database; do
    setup_world "no-op-$form"
    python3 -I - "$NM_DIR" "$form" <<'PY'
import json, sqlite3, sys
from pathlib import Path
root, form = Path(sys.argv[1]), sys.argv[2]
p = root / "status.toon"
s = p.read_text().replace("QD-8,warning,app.py,ask-user", "QD-8,warning,app.py,no-op")
if form == "scalar":
    s = s.replace("gate:\n  step: review", "gate: review")
elif form == "database":
    s = s.split("  findings[", 1)[0]
    with sqlite3.connect(root / "state.sqlite") as db:
        db.execute("UPDATE step_rounds SET findings_json = ? WHERE round = 2",
                   (json.dumps({"findings": [{"id": "QD-8", "action": "no-op"},
                                            {"id": "QD-11", "action": "auto-fix"},
                                            {"id": "QD-12", "action": "no-op"}]}),))
p.write_text(s)
PY
    expect_refusal "$form carried no-op omission" "incomplete decision: no decision for QD-8,QD-12" --fix QD-11
    expect_refusal "$form approval omission" "incomplete decision: no decision for QD-12" --approve QD-8,QD-11 --reason "accepted"
    expect_refusal "$form no-change omission" "incomplete decision: no decision for QD-12" --no-change QD-8,QD-11
    assert_absent "$HOME_DIR/state/t1.inbox" "an omitted no-op sends nothing"
    assert_absent "$HOME_DIR/data/t1/gate-decisions.jsonl" "an omitted no-op records nothing"
    out=$(helper --fix QD-11 --no-change QD-8,QD-12 2>&1) || fail "$form complete decision should preview: $out"
    assert_contains "$out" "- QD-8 [no-op]: no change" "the steer retains the carried no-op decision"
    assert_contains "$out" "- QD-8: in round 1; round 1 selected it for a fix; fix round 2 moved" "the steer retains carried no-op fix evidence"
    assert_contains "$out" "re-verify each at pipeline head ${HEAD_SHA:0:12}" "the evidence includes the current pipeline head"
    assert_no_respond
  done
  pass "fm-gate-decide: requires explicit no-op decisions in every findings representation"
}

test_refusals() {
  local out digest
  setup_world refusals
  expect_refusal "--yes" "--yes is banned" --fix QD-8,QD-11 --yes
  expect_refusal "-y as a value" "--yes is banned" --fix QD-8,QD-11 --instructions -y
  expect_refusal "unknown id" "QD-99 is not in the current round" --fix QD-8,QD-11,QD-99
  expect_refusal "duplicate id" "QD-8 is decided more than once" --fix QD-8,QD-11 --no-change QD-8
  expect_refusal "incomplete" "incomplete decision: no decision for QD-11" --fix QD-8
  expect_refusal "approve without reason" "--approve QD-8 needs a --reason" --approve QD-8 --fix QD-11
  expect_refusal "instructions without fix" "only reach the fixer" --no-change QD-8,QD-11,QD-12 --instructions "x"
  expect_refusal "key override" "unknown argument '--key'" --fix QD-8,QD-11 --key other
  expect_refusal "skip alias" "unknown argument '--skip'" --skip QD-8,QD-11
  expect_refusal "no decision" "no decision given"
  out=$(helper --fix QD-8,QD-11 --no-change QD-12); digest=$(digest_of "$out")
  expect_refusal "stale digest" "the gate changed since the preview" --fix QD-8,QD-11 --no-change QD-12 --instructions "different" --confirm "$digest"
  assert_absent "$HOME_DIR/state/t1.inbox" "no refusal sends anything"
  assert_absent "$HOME_DIR/data/t1/gate-decisions.jsonl" "no refusal records anything"
  assert_no_respond
  pass "fm-gate-decide: refuses --yes, foreign or duplicate ids, incomplete decisions, and stale previews"
}

test_refuses_unparked_drifted_or_disagreeing_state() {
  setup_world unparked
  printf 'run:\n  id: "%s"\n  branch: fm/t1\n  status: running\n  head_sha: %s\n' "$RUN" "$HEAD_SHA" > "$NM_DIR/status.toon"
  expect_refusal "not parked" "is not parked at a gate" --fix QD-8,QD-11
  setup_world drift
  rm -f "$NM_DIR/state.sqlite"; make_db selected_finding_ids
  expect_refusal "schema drift" "no-mistakes state schema drift: step_rounds lacks selected_finding_ids" --fix QD-8,QD-11
  setup_world disagree
  write_status review "$(printf '%s\n' '    QD-8,warning,app.py,ask-user,"x"')" 1
  expect_refusal "gate and database disagree" "disagree with no-mistakes state round 2" --fix QD-8
  setup_world competing
  cat > "$NM_DIR/overview.toon" <<EOF
repo: $TMP_ROOT/competing/repo
count: 2 of 2 total
runs[2]{id,branch,status,head,pr}:
  "$RUN",fm/t1,running,${HEAD_SHA:0:8},""
  "01TESTRUN0000000000000000B",fm/t1,running,${HEAD_SHA:0:8},""
EOF
  expect_refusal "competing runs" "cannot attribute one run" --fix QD-8,QD-11
  assert_no_respond
  pass "fm-gate-decide: refuses an unparked run, schema drift, gate/state disagreement, and competing runs"
}

test_preview_is_read_only_and_annotates_carried_ids
test_confirm_sends_closes_and_records
test_gate_authority_before_recording
test_refused_send_records_nothing
test_refused_send_ignores_earlier_identical_steer
test_partial_delivery_preserves_decision
test_final_verification_refuses_changes
test_later_round_reads_the_earlier_decision
test_command_is_argument_safe
test_approve_only_maps_to_approve
test_scalar_gate_form
test_no_op_requires_explicit_decisions
test_refusals
test_refuses_unparked_drifted_or_disagreeing_state
