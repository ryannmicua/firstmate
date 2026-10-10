#!/usr/bin/env bash
# fm-gate-decide.sh - compose firstmate's decision for a task's parked
# no-mistakes gate and send it to the task worker as one exact steer.
#
# Usage:
#   fm-gate-decide.sh <task-id> [--fix <ids>]... [--no-change <ids> [--reason <text>]]...
#                     [--approve <ids> --reason <text>]... [--instructions <text>]
#                     [--confirm <digest>]
#   <ids> is a comma-separated list of finding ids from the CURRENT gate.
#   A --reason applies to the --approve or --no-change group immediately
#   before it, and every --approve needs one.
#   --instructions is firstmate's guidance for the findings being fixed.
#
# Firstmate still makes every decision and the worker still drives the
# pipeline: this script never runs `no-mistakes axi respond` itself. It only
# removes the busywork of the hand-written decision steer.
#
# Without --confirm it is a read-only preview: it resolves the task's run and
# parked gate, validates the decision, and prints the exact steer it would
# send plus the command that sends it. With --confirm <digest> it re-resolves
# everything, recomposes the steer, and sends it only when the digest of the
# fresh steer still equals the previewed one, so a gate that moved between
# preview and send is refused rather than answered with a stale decision.
# The run, parked step, round, finding IDs/actions, and pipeline head are read
# again and compared immediately before recording and attempting delivery.
#
# Resolution (read-only, bin/fm-nm-run-lib.sh owns the attribution rules):
#   - the task's worktree from state/<task>.meta and its checked-out branch;
#   - the branch's run from the `no-mistakes axi` overview (fm_nm_select_run)
#     and the worktree's implicit current-branch `axi status`, which must name
#     the same run - the gate the worker's respond call will answer;
#   - the run must be active and parked, and bound to the worktree by head or
#     by active pipeline custody;
#   - the gate step and the current round's finding ids come from the status
#     output's gate block; the pipeline head is branch_sync.pipeline.current_head
#     (else the run's head_sha).
# Round history comes from no-mistakes' state database (fm_nm_state_db), read
# with SQLite mode=ro. It is no-mistakes' private schema, so a missing table or
# column, an unexpected findings_json shape, a database round whose finding
# ids disagree with the gate, or a gate without a findings table and no
# readable database round refuses loudly instead of guessing. The database
# also supplies the current ids when the gate prints no findings table.
#
# Refusals (exit 1, nothing sent or recorded): --yes or -y anywhere in the
# arguments; an id not in the current round; an id decided twice; a current
# finding left undecided; --approve
# without --reason; --instructions with no --fix; no decision at all.
#
# Carried-over findings: an id that also appeared in an earlier round of the
# same run and step is never dropped. It is annotated with every earlier round
# it appeared in, whether that round selected it for a fix and what the
# following fix round recorded (head move and fix summary), and firstmate's
# earlier decision for it from this script's own record. That context is
# prepended to --instructions, together with the current pipeline head, so the
# fixer re-verifies at head before re-fixing or re-raising.
#
# Response mapping (one respond call answers the whole gate):
#   - any --fix: `--action fix --findings <fix ids> --instructions <text>`,
#     where <text> is the carried-over context, then --instructions, then one
#     "leave unchanged" line per --no-change or --approve id;
#   - otherwise: `--action approve`, plus `--reason` only on the test step,
#     the one step whose approval preserves a reason.
#   Every command names `--step <step>` so it can never answer a different gate.
#   Arguments are single-quoted for a POSIX shell, so any text is safe.
# The steer carries the decisions, the command, and the standing etiquette from
# one fixed template, and is sent through fm-send.sh with --resolve-key for the
# decision key, so the worker's open decision record closes at answer time.
#
# Durable record: before attempting delivery, one JSON line (schema
# fm-gate-decision.v1: task, run, step, round, key, pipeline head, per-finding
# decisions, firstmate's instructions, the respond arguments, the command, the
# digest) is appended to <data>/<task>/gate-decisions.jsonl, where later rounds
# read it back as the earlier decision, not as proof of delivery.
#
# Environment: FM_HOME must be set explicitly, as fm-send.sh requires.
# FM_STATE_OVERRIDE and FM_DATA_OVERRIDE relocate state/ and data/.
# Each no-mistakes CLI read has a fixed 20-second timeout.
# Exit: 0 preview printed or steer sent and recorded; 1 refused or unresolved;
# 2 usage; 3 fm-send failed (delivery uncertain; do not resend without checking);
# 4 durable record append failed (nothing sent).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"

usage() {
  sed -n '4,13p' "$0" | sed 's/^# \{0,1\}//'
}

die() {
  echo "error: $*" >&2
  exit 1
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  ''|-*) usage >&2; exit 2 ;;
esac
TASK=$1
shift
case "$TASK" in *[!A-Za-z0-9._-]*) echo "error: invalid task id '$TASK'" >&2; exit 2 ;; esac

ORIG_ARGS=("$@")
DECISIONS=()   # "<action>"$'\t'"<id>" entries; reasons attach per group
REASONS=()     # parallel to DECISIONS
INSTRUCTIONS=''
CONFIRM=''
last_group_start=-1
last_group_action=''
reason_taken=0

add_group() {  # <action> <ids>
  local action=$1 ids=$2 id rest
  [ -n "$ids" ] || { echo "error: --$action needs a comma-separated id list" >&2; exit 2; }
  last_group_start=${#DECISIONS[@]}
  last_group_action=$action
  reason_taken=0
  rest=$ids
  while :; do
    id=${rest%%,*}
    id=$(fm_nm_trim "$id")
    [ -n "$id" ] || { echo "error: empty finding id in '$ids'" >&2; exit 2; }
    DECISIONS+=("$action"$'\t'"$id")
    REASONS+=("")
    case "$rest" in *,*) rest=${rest#*,} ;; *) break ;; esac
  done
}

need_value() {  # <flag> <remaining-count>
  [ "$2" -ge 2 ] || { echo "error: $1 requires a value" >&2; exit 2; }
}

while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y|--yes=*)
      die "--yes is banned fleet-wide: it auto-resolves gates, including ask-user findings, without a decision" ;;
    --fix) need_value "$1" $#; add_group fix "$2"; shift 2 ;;
    --no-change) need_value "$1" $#; add_group no-change "$2"; shift 2 ;;
    --approve) need_value "$1" $#; add_group approve "$2"; shift 2 ;;
    --reason)
      need_value "$1" $#
      case "$last_group_action" in
        approve|no-change) ;;
        *) echo "error: --reason must follow an --approve or --no-change group" >&2; exit 2 ;;
      esac
      [ "$reason_taken" = 0 ] || { echo "error: one --reason per --$last_group_action group" >&2; exit 2; }
      [ -n "$(fm_nm_trim "$2")" ] || { echo "error: --reason must not be empty" >&2; exit 2; }
      i=$last_group_start
      while [ "$i" -lt "${#DECISIONS[@]}" ]; do REASONS[i]=$2; i=$((i + 1)); done
      reason_taken=1
      shift 2 ;;
    --instructions)
      need_value "$1" $#
      [ -z "$INSTRUCTIONS" ] || { echo "error: --instructions given twice" >&2; exit 2; }
      INSTRUCTIONS=$2; shift 2 ;;
    --confirm) need_value "$1" $#; CONFIRM=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
done
# A value that is itself a --yes flag (for example `--fix --yes`) was consumed
# as data above; refuse it here too so the banned flag can never ride along.
for a in ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}; do
  case "$a" in --yes|-y|--yes=*) die "--yes is banned fleet-wide: it auto-resolves gates, including ask-user findings, without a decision" ;; esac
done

[ "${#DECISIONS[@]}" -gt 0 ] || die "no decision given: name every current finding with --fix, --no-change, or --approve"
i=0
while [ "$i" -lt "${#DECISIONS[@]}" ]; do
  case "${DECISIONS[i]}" in
    approve$'\t'*) [ -n "${REASONS[i]}" ] || die "--approve ${DECISIONS[i]#*$'\t'} needs a --reason" ;;
  esac
  i=$((i + 1))
done
case "$CONFIRM" in ''|[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;; *) echo "error: --confirm takes the digest a preview printed" >&2; exit 2 ;; esac

if [ -z "${FM_HOME:-}" ]; then
  echo "error: FM_HOME is not set; fm-gate-decide refuses to resolve a task without an explicit firstmate home" >&2
  exit 2
fi
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
DATA=${FM_DATA_OVERRIDE:-$FM_HOME/data}
NM_TIMEOUT=20
command -v python3 >/dev/null 2>&1 || die "python3 is required to read the gate and its round history"
command -v no-mistakes >/dev/null 2>&1 || die "no-mistakes is not on PATH"

# --- resolve the task's run and parked gate (read-only) ---------------------

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-gate-decide.XXXXXX") || die "cannot create a scratch directory"
trap 'rm -rf "$WORK"' EXIT

read_gate() {
META="$STATE/$TASK.meta"
[ -f "$META" ] || die "no metadata for task '$TASK' at $META"
meta_value() {  # <key>
  grep "^$1=" "$META" 2>/dev/null | tail -1 | cut -d= -f2- || true
}
WT=$(meta_value worktree)
[ -n "$WT" ] && [ -d "$WT" ] || die "task '$TASK' has no local worktree on record"
[ -z "$(meta_value remote_host)" ] || die "task '$TASK' runs on a remote host; decide its gate there"
BRANCH=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null) || die "worktree $WT is not on a branch"
META_BRANCH=$(meta_value branch)
[ -z "$META_BRANCH" ] || [ "$META_BRANCH" = "$BRANCH" ] \
  || die "worktree branch '$BRANCH' does not match the recorded ship branch '$META_BRANCH'"

OVERVIEW=$(fm_nm_run_checked "$WT" "$NM_TIMEOUT" axi) || die "no-mistakes axi overview failed or timed out in $WT"
CHOICE=$(fm_nm_select_run "$BRANCH" "$OVERVIEW" "$WT" "$NM_TIMEOUT")
STATUS_OUT=$(fm_nm_run_checked "$WT" "$NM_TIMEOUT" axi status) || die "no-mistakes axi status failed or timed out in $WT"
case "$STATUS_OUT" in
  error:*|*$'\n'error:*) die "no-mistakes axi status reported: $(printf '%s\n' "$STATUS_OUT" | sed -n 's/^error: //p' | head -1)" ;;
esac
case "$CHOICE" in
  selected\|*) SELECTED_ID=$(printf '%s' "$CHOICE" | cut -d'|' -f2) ;;
  absent) die "no no-mistakes run exists for branch '$BRANCH'" ;;
  *) die "cannot attribute one run to branch '$BRANCH': ${CHOICE#*|}" ;;
esac
RUN_ID=$(fm_nm_strip_quotes "$(fm_nm_field "$STATUS_OUT" id)")
RUN_BRANCH=$(fm_nm_strip_quotes "$(fm_nm_field "$STATUS_OUT" branch)")
[ -n "$RUN_ID" ] || die "axi status shows no current-branch run in $WT"
[ "$RUN_ID" = "$SELECTED_ID" ] \
  || die "the worktree's current run $RUN_ID is not the branch's newest run $SELECTED_ID"
[ "$RUN_BRANCH" = "$BRANCH" ] || die "run $RUN_ID belongs to branch '$RUN_BRANCH', not '$BRANCH'"
fm_nm_run_is_active "$STATUS_OUT" || die "run $RUN_ID is no longer active"
fm_nm_run_is_parked "$STATUS_OUT" || die "run $RUN_ID is not parked at a gate"
RUN_HEAD=$(fm_nm_strip_quotes "$(fm_nm_field "$STATUS_OUT" head_sha)")
[ -n "$RUN_HEAD" ] || RUN_HEAD=$(fm_nm_strip_quotes "$(fm_nm_field "$STATUS_OUT" head)")
fm_nm_head_matches_worktree "$WT" "$RUN_HEAD" || fm_nm_run_is_pipeline_owned_active "$STATUS_OUT" \
  || die "run $RUN_ID cannot be bound to worktree $WT by head or by pipeline custody"
PIPELINE_HEAD=$(fm_nm_branch_sync_nested "$STATUS_OUT" pipeline current_head)
[ -n "$PIPELINE_HEAD" ] || PIPELINE_HEAD=$RUN_HEAD
case "$PIPELINE_HEAD" in *[!0-9a-fA-F]*|'') die "run $RUN_ID reports no readable pipeline head" ;; esac

RECORD="$DATA/$TASK/gate-decisions.jsonl"
DB=$(fm_nm_state_db "$WT")
printf '%s' "$STATUS_OUT" > "$WORK/status.toon"
: > "$WORK/decisions.bin"
i=0
while [ "$i" -lt "${#DECISIONS[@]}" ]; do
  # NUL-separated so a reason may hold any text, including tabs and newlines.
  printf '%s\0%s\0' "${DECISIONS[i]}" "${REASONS[i]}" >> "$WORK/decisions.bin"
  i=$((i + 1))
done

# --- compose (deterministic; refuses on any inconsistency) ------------------

python3 -I - "$WORK" "$DB" "$RUN_ID" "$RECORD" "$TASK" "$PIPELINE_HEAD" "$INSTRUCTIONS" "$1" <<'PY' || exit 1
import hashlib
import json
import os
import re
import sqlite3
import sys
from contextlib import closing
from pathlib import Path

work, db_path, run_id, record_path, task, head, instructions, mode = sys.argv[1:]


def die(msg):
    print("error: " + msg, file=sys.stderr)
    sys.exit(1)


# Gate block of the status TOON: step plus the findings table that follows it.
def toon_scalar(s):
    s = s.strip()
    if s.startswith('"'):
        try:
            return json.loads(s)
        except ValueError:
            die("unreadable quoted value in the gate block: " + s[:80])
    return s


def toon_row(s):
    out, i, n = [], 0, len(s)
    dec = json.JSONDecoder()
    while i <= n:
        while i < n and s[i] == " ":
            i += 1
        if i < n and s[i] == '"':
            try:
                val, i = dec.raw_decode(s, i)
            except ValueError:
                die("unreadable quoted cell in the gate findings table")
            out.append(val)
            while i < n and s[i] == " ":
                i += 1
            if i < n and s[i] != ",":
                die("unexpected text after a quoted cell in the gate findings table")
        else:
            j = s.find(",", i)
            j = n if j < 0 else j
            out.append(s[i:j].strip())
            i = j
        i += 1
    return out


lines = Path(work, "status.toon").read_text().splitlines()
gate_at = next((k for k, l in enumerate(lines) if re.match(r"^\s*gate:", l)), None)
if gate_at is None:
    die("the status output has no gate block")
gate_indent = len(lines[gate_at]) - len(lines[gate_at].lstrip())
step = toon_scalar(lines[gate_at].split(":", 1)[1])
# Block form (`gate:` with indented children) ends at the first line back at
# the gate's indentation; scalar form (`gate: <step>` with sibling fields)
# ends at the help list.
block = []
for l in lines[gate_at + 1:]:
    if step and re.match(r"^\s*help\[", l) and len(l) - len(l.lstrip()) <= gate_indent:
        break
    if not step and l.strip() and len(l) - len(l.lstrip()) <= gate_indent:
        break
    block.append(l)
if not step:
    m = next((re.match(r"^\s*step:\s*(.*)$", l) for l in block if re.match(r"^\s*step:", l)), None)
    step = toon_scalar(m.group(1)) if m else ""
if not re.fullmatch(r"[a-z][a-z0-9_-]*", step or ""):
    die("cannot read the gate step from the status output")

gate = None
for k, l in enumerate(block):
    m = re.match(r"^\s*findings\[(\d+)\]\{([^}]*)\}:\s*$", l)
    if not m:
        continue
    cols = [c.strip() for c in m.group(2).split(",")]
    if "id" not in cols or "action" not in cols:
        die("gate findings table has no id or action column: " + m.group(2))
    count = int(m.group(1))
    rows = block[k + 1:k + 1 + count]
    if len(rows) != count:
        die("gate findings table is truncated")
    gate = []
    for r in rows:
        cells = toon_row(r.strip())
        # An unquoted trailing free-text cell may hold commas; fold the overflow
        # back into the last column as long as id and action precede it.
        last = len(cols) - 1
        if len(cells) > len(cols) and max(cols.index("id"), cols.index("action")) < last:
            cells = cells[:last] + [",".join(cells[last:])]
        if len(cells) != len(cols):
            die("gate findings row does not match its header: " + r.strip()[:80])
        rec = dict(zip(cols, cells))
        gate.append({"id": rec["id"], "action": rec["action"]})
    break


# Round history from no-mistakes' private state database, schema-checked.
REQUIRED = {
    "step_results": {"id", "run_id", "step_name"},
    "step_rounds": {"step_result_id", "round", "findings_json", "selected_finding_ids",
                    "fix_summary", "reviewed_head_sha", "starting_head_sha"},
}
if not os.path.isfile(db_path):
    die("no-mistakes state database not found at " + db_path)
try:
    with closing(sqlite3.connect(Path(db_path).as_uri() + "?mode=ro", uri=True, timeout=30)) as db:
        for table, cols in REQUIRED.items():
            have = {row[1] for row in db.execute("PRAGMA table_info(%s)" % table)}
            missing = cols - have
            if missing:
                die("no-mistakes state schema drift: %s lacks %s" % (table, ", ".join(sorted(missing))))
        results = db.execute("SELECT id FROM step_results WHERE run_id = ? AND step_name = ?",
                             (run_id, step)).fetchall()
        if len(results) != 1:
            die("no-mistakes state has %d step records for run %s step %s" % (len(results), run_id, step))
        rounds = db.execute(
            "SELECT round, findings_json, selected_finding_ids, fix_summary, reviewed_head_sha, starting_head_sha "
            "FROM step_rounds WHERE step_result_id = ? ORDER BY round", (results[0][0],)).fetchall()
except sqlite3.Error as e:
    die("cannot read the no-mistakes state database: %s" % e)
if not rounds:
    die("no-mistakes state has no rounds for run %s step %s" % (run_id, step))


def round_findings(raw, rnd):
    try:
        doc = json.loads(raw) if raw else {"findings": []}
        items = doc["findings"] if isinstance(doc, dict) else None
        if not isinstance(items, list) or not all(isinstance(f, dict) and isinstance(f.get("id"), str) for f in items):
            raise ValueError
    except (ValueError, KeyError, TypeError):
        die("no-mistakes state schema drift: round %s findings_json is not {findings:[{id,...}]}" % rnd)
    return items


def id_list(raw, rnd):
    if not raw:
        return []
    try:
        ids = json.loads(raw)
        if not isinstance(ids, list) or not all(isinstance(x, str) for x in ids):
            raise ValueError
    except ValueError:
        die("no-mistakes state schema drift: round %s selected_finding_ids is not a JSON id list" % rnd)
    return ids


history = []
for rnd, fj, sel, summary, reviewed, starting in rounds:
    history.append({"round": rnd, "findings": round_findings(fj, rnd), "selected": id_list(sel, rnd),
                    "fix_summary": summary or "", "reviewed": reviewed or "", "starting": starting or ""})
current = history[-1]
db_ids = [f["id"] for f in current["findings"]]
if gate is None:
    gate = [{"id": f["id"], "action": f.get("action", "")} for f in current["findings"]]
    if not gate:
        die("the gate shows no findings table and the state database's current round has none")
elif sorted(f["id"] for f in gate) != sorted(db_ids):
    die("the gate's findings (%s) disagree with no-mistakes state round %s (%s)"
        % (",".join(f["id"] for f in gate), current["round"], ",".join(db_ids)))
current_ids = [f["id"] for f in gate]
gate_action = {f["id"]: f["action"] for f in gate}

snapshot = {"run": run_id, "step": step, "round": current["round"],
            "findings": sorted(gate, key=lambda f: f["id"]), "pipeline_head": head}
Path(work, "snapshot.json").write_text(json.dumps(snapshot, sort_keys=True))
if mode == "verify":
    sys.exit(0)

# Validate the decision against the current round.
raw = Path(work, "decisions.bin").read_bytes().split(b"\0")[:-1]
decisions = []
for k in range(0, len(raw), 2):
    action, fid = raw[k].decode().split("\t", 1)
    decisions.append({"id": fid, "action": action, "reason": raw[k + 1].decode()})
seen = set()
for d in decisions:
    if d["id"] not in current_ids:
        die("finding %s is not in the current round of step %s (current: %s)" % (d["id"], step, ",".join(current_ids)))
    if d["id"] in seen:
        die("finding %s is decided more than once" % d["id"])
    seen.add(d["id"])
undecided = [i for i in current_ids if i not in seen]
if undecided:
    die("incomplete decision: no decision for %s" % ",".join(undecided))
fixes = [d for d in decisions if d["action"] == "fix"]
keeps = [d for d in decisions if d["action"] != "fix"]
if instructions.strip() and not fixes:
    die("--instructions only reach the fixer with at least one --fix")

# Earlier decisions from this script's own durable record, same run and step.
earlier = {}
if os.path.isfile(record_path):
    with open(record_path) as fh:
        for n, line in enumerate(fh, 1):
            try:
                rec = json.loads(line)
            except ValueError:
                die("unreadable line %d in %s" % (n, record_path))
            if rec.get("run") != run_id or rec.get("step") != step:
                continue
            for d in rec.get("decisions", []):
                earlier.setdefault(d.get("id"), []).append(
                    {"round": rec.get("round"), "action": d.get("action"), "reason": d.get("reason", ""),
                     "instructions": rec.get("instructions", ""), "head": rec.get("pipeline_head", "")})

short = lambda s: (s or "")[:12]
excerpt = lambda s, n=240: (" ".join(s.split())[:n] + ("..." if len(" ".join(s.split())) > n else ""))
carried = []
for fid in current_ids:
    prior = [h for h in history[:-1] if fid in {f["id"] for f in h["findings"]}]
    if not prior:
        continue
    parts = ["in round%s %s" % ("s" if len(prior) > 1 else "", ",".join(str(h["round"]) for h in prior))]
    for h in prior:
        if fid in h["selected"]:
            nxt = next((x for x in history if x["round"] == h["round"] + 1), None)
            if nxt and nxt["reviewed"]:
                parts.append("round %s selected it for a fix; fix round %s moved %s -> %s (%s)"
                             % (h["round"], nxt["round"], short(nxt["starting"]), short(nxt["reviewed"]),
                                excerpt(nxt["fix_summary"], 80) or "no fix summary"))
            else:
                parts.append("round %s selected it for a fix" % h["round"])
    for e in earlier.get(fid, []):
        said = e["action"] + (": " + excerpt(e["reason"], 160) if e["reason"] else "")
        if e["action"] == "fix" and e["instructions"]:
            said += "; instructions: " + excerpt(e["instructions"])
        parts.append("round %s firstmate decision at head %s: %s" % (e["round"], short(e["head"]), said))
    carried.append("- %s: %s" % (fid, "; ".join(parts)))


def label(d):
    if d["action"] == "fix":
        return "fix"
    word = "approve" if d["action"] == "approve" else "no change"
    return word + (" - " + " ".join(d["reason"].split()) if d["reason"] else "")


carry_text = ""
if carried:
    carry_text = ("Carried over from earlier rounds - re-verify each at pipeline head %s before re-fixing or "
                  "re-raising; if that head already satisfies it, leave it as is:\n" % short(head)) + "\n".join(carried)

sq = lambda s: "'" + s.replace("'", "'\\''") + "'"
if fixes:
    parts = []
    if carry_text:
        parts.append(carry_text)
    if instructions.strip():
        parts.append(instructions.strip())
    if keeps:
        parts.append("Leave these findings unchanged:\n" + "\n".join("- %s: %s" % (d["id"], label(d)) for d in keeps))
    respond = {"action": "fix", "findings": [d["id"] for d in fixes], "instructions": "\n\n".join(parts)}
    argv = ["no-mistakes", "axi", "respond", "--step", step, "--action", "fix",
            "--findings", ",".join(respond["findings"])]
    if respond["instructions"]:
        argv += ["--instructions", respond["instructions"]]
else:
    respond = {"action": "approve", "findings": [], "instructions": ""}
    argv = ["no-mistakes", "axi", "respond", "--step", step, "--action", "approve"]
    reasons = ["%s: %s" % (d["id"], " ".join(d["reason"].split())) for d in keeps if d["reason"]]
    if step == "test" and reasons:
        respond["reason"] = "; ".join(reasons)
        argv += ["--reason", respond["reason"]]
command = " ".join(a if re.fullmatch(r"[A-Za-z0-9_.,/=:+-]+", a) else sq(a) for a in argv)

round_no = current["round"]
key = "nm-%s-%s" % (run_id, step)
msg = ["Gate decision from firstmate for no-mistakes run %s, step %s, round %s, pipeline head %s."
       % (run_id, step, round_no, head),
       "This answers decision key %s." % key, "", "Decisions:"]
msg += ["- %s%s: %s" % (d["id"], " [%s]" % gate_action[d["id"]] if gate_action.get(d["id"]) else "", label(d))
        for d in decisions]
if carry_text:
    msg += ["", carry_text if fixes else carry_text + "\n(Context only: an approval sends no instructions to the fixer.)"]
msg += ["", "Run exactly this command in your worktree, backgrounded as your brief describes, without editing it:",
        command, "",
        "Never add --yes or -y. Process every return of that call and of any reattach until checks-passed, "
        "a final outcome, or a genuinely new escalation; report a new ask-user gate with your brief's "
        "needs-decision format and stop."]
message = "\n".join(msg)
digest = hashlib.sha256(message.encode()).hexdigest()[:16]
record = {"schema": "fm-gate-decision.v1", "task": task, "run": run_id, "step": step, "round": round_no,
          "key": key, "pipeline_head": head, "decisions": decisions, "instructions": instructions,
          "respond": respond, "command": command, "digest": digest}
Path(work, "message.txt").write_text(message)
Path(work, "key").write_text(key)
Path(work, "digest").write_text(digest)
Path(work, "record.json").write_text(json.dumps(record, sort_keys=True) + "\n")
PY
}

read_gate compose

MESSAGE=$(cat "$WORK/message.txt")
DIGEST=$(cat "$WORK/digest")
KEY=$(cat "$WORK/key")

if [ -z "$CONFIRM" ]; then
  printf '%s\n' "--- steer preview for task $TASK (not sent) ---" "$MESSAGE" "--- end of preview ---"
  printf 'digest: %s\n' "$DIGEST"
  printf 'send it with: FM_HOME=%q %q %q' "$FM_HOME" "$0" "$TASK"
  [ "${#ORIG_ARGS[@]}" -eq 0 ] || printf ' %q' "${ORIG_ARGS[@]}"
  printf ' --confirm %s\n' "$DIGEST"
  exit 0
fi

[ "$CONFIRM" = "$DIGEST" ] \
  || die "the gate changed since the preview (digest $CONFIRM, now $DIGEST); preview again before sending"

cp "$WORK/snapshot.json" "$WORK/expected-snapshot.json" || die "cannot retain the gate snapshot"
read_gate verify
cmp -s "$WORK/expected-snapshot.json" "$WORK/snapshot.json" \
  || die "the gate changed immediately before delivery; preview again before sending"

if ! { mkdir -p "$DATA/$TASK" && cat "$WORK/record.json" >> "$RECORD"; }; then
  echo "error: the decision could not be recorded in $RECORD; nothing was sent" >&2
  exit 4
fi
FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-send.sh" "$TASK" --resolve-key "$KEY" "$MESSAGE" || {
  echo "error: fm-send failed; the decision is preserved in $RECORD, but delivery may have occurred; check the worker inbox and decision closure before any resend" >&2
  exit 3
}
printf 'sent: decision for task %s, run %s (key %s, digest %s); recorded in %s\n' \
  "$TASK" "$RUN_ID" "$KEY" "$DIGEST" "$RECORD"
