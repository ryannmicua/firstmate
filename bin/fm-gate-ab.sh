#!/usr/bin/env bash
# fm-gate-ab.sh - A/B experiment for firstmate's gate decisions: the decision
# helper (bin/fm-gate-decide.sh) against a hand-written steer.
#
# Usage:
#   fm-gate-ab.sh assign <key>
#   fm-gate-ab.sh log <key> --task <id> --round <n> [--fix <ids>] [--no-change <ids>] [--approve <ids>]
#                       [--arm helper|manual] [--digest <digest>]
#   fm-gate-ab.sh report [--baseline-days <n>] [--since <epoch>] [--transcripts <dir>]
#
# The experiment is opt-in: it is enabled only while config/gate-ab exists.
#   assign   prints `helper` or `manual` for a decision key
#            (nm-<run>-<step>), from a stable hash of the key, so every round
#            of one gate lands in one arm. Without config/gate-ab it prints
#            `helper`, the default. fm-gate-decide.sh refuses a key assigned
#            to `manual`.
#   log      is what firstmate runs after sending a hand-written decision
#            (arm manual). <ids> are comma-separated finding ids of the round;
#            every id of the round is named in exactly one group.
#            --arm helper and --digest are for fm-gate-decide.sh's own line.
#   report   prints, per arm and for a baseline, the decision count and the
#            measures below, each with its own sample size.
#
# Decision log: <data>/gate-ab.jsonl, append-only, one JSON line per decision
# (schema fm-gate-ab.v1: key, arm, task, run, step, round, findings [{id,
# action}], digest for the helper arm, at). fm-gate-decide.sh appends the
# helper arm's line itself, only while the experiment is enabled and only
# after its own record is written. Nothing is recorded outside the experiment.
#
# Measures (all read from existing records, never from a judgment):
#   tokens        firstmate Claude session transcripts under
#                 ~/.claude/projects/<FM_HOME with / and . as ->/ (or
#                 --transcripts): the whole turn holding the tool call that
#                 sent the decision (helper: `--confirm <digest>`; manual and
#                 baseline: the decision key with fm-send.sh).
#                 Reported as output tokens and as output + input + cache
#                 creation; cache reads are left out. The turn also holds any
#                 unrelated work done in it, so read it as an upper bound.
#   extra rounds  later rounds of the same step that selected findings for a
#                 fix again, and decided findings re-selected in them, from
#                 no-mistakes' step_rounds (selected_finding_ids).
#   park->done    seconds from a timestamped needs-decision event for the
#                 round to the step's completion (step_results.completed_at);
#                 missing park events and steps still open are left out.
#   respond lines blocked/failed worker status lines between the round's
#                 creation and its resolution that name a respond problem
#                 (reject, refus, malformed, invalid, unknown, error, ...).
# Baseline: fix decisions (step_rounds.selection_source = 'user') made before
# the experiment started, from --baseline-days (default 30) before its start,
# that are in no helper record. The start is config/gate-ab's mtime unless
# --since is given. Approvals leave no selection row, so the baseline holds
# fix decisions only, attributable to tasks in this home through status or
# retained decision/event logs. Missing status history leaves respond lines
# unavailable; missing or ambiguous transcript delivery leaves tokens unavailable.
# The report states sample sizes and makes no significance claim.
#
# The no-mistakes state database (fm_nm_state_db) is read with SQLite mode=ro;
# a missing table or column exits 1 naming it, rather than guessing.
# Environment: FM_HOME is required. FM_STATE_OVERRIDE, FM_DATA_OVERRIDE and
# FM_CONFIG_OVERRIDE relocate state/, data/ and config/; FM_GATE_AB_NOW fixes
# the clock for tests.
# Exit: 0 ok; 1 refused or unreadable source; 2 usage.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"

usage() {
  sed -n '4,9p' "$0" | sed 's/^# \{0,1\}//'
}

die() {
  echo "error: $*" >&2
  exit 1
}

CMD=${1:-}
case "$CMD" in
  -h|--help) usage; exit 0 ;;
  assign|log|report) shift ;;
  *) usage >&2; exit 2 ;;
esac
if [ -z "${FM_HOME:-}" ]; then
  echo "error: FM_HOME is not set; fm-gate-ab refuses to use an implicit firstmate home" >&2
  exit 2
fi
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
DATA=${FM_DATA_OVERRIDE:-$FM_HOME/data}
CONFIG=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}
FLAG="$CONFIG/gate-ab"
LOG="$DATA/gate-ab.jsonl"
command -v python3 >/dev/null 2>&1 || die "python3 is required"

valid_key() {
  case "$1" in
    nm-[A-Za-z0-9]*-[a-z]*) ;;
    *) return 1 ;;
  esac
  case "$1" in *[!A-Za-z0-9_-]*|*--*) return 1 ;; esac
}

assign() {  # <key>
  if [ ! -e "$FLAG" ]; then
    echo helper
    return 0
  fi
  python3 -I -c 'import hashlib, sys
print("helper" if hashlib.sha256(b"fm-gate-ab.v1:" + sys.argv[1].encode()).digest()[0] & 1 else "manual")' "$1"
}

case "$CMD" in
  assign)
    [ $# -eq 1 ] || { usage >&2; exit 2; }
    valid_key "$1" || { echo "error: '$1' is not a decision key (nm-<run>-<step>)" >&2; exit 2; }
    assign "$1"
    ;;

  log)
    [ $# -ge 1 ] || { usage >&2; exit 2; }
    KEY=$1; shift
    valid_key "$KEY" || { echo "error: '$KEY' is not a decision key (nm-<run>-<step>)" >&2; exit 2; }
    TASK=''; ROUND=''; ARM=manual; DIGEST=''
    ARGS=()
    while [ $# -gt 0 ]; do
      [ $# -ge 2 ] || { echo "error: $1 requires a value" >&2; exit 2; }
      case "$1" in
        --task) TASK=$2 ;;
        --round) ROUND=$2 ;;
        --arm) ARM=$2 ;;
        --digest) DIGEST=$2 ;;
        --fix|--no-change|--approve) ARGS+=("${1#--}" "$2") ;;
        *) echo "error: unknown argument '$1'" >&2; exit 2 ;;
      esac
      shift 2
    done
    case "$TASK" in ''|*[!A-Za-z0-9._-]*) echo "error: --task needs a task id" >&2; exit 2 ;; esac
    case "$ROUND" in ''|*[!0-9]*) echo "error: --round needs a round number" >&2; exit 2 ;; esac
    case "$ARM" in helper|manual) ;; *) echo "error: --arm is helper or manual" >&2; exit 2 ;; esac
    [ "${#ARGS[@]}" -gt 0 ] || { echo "error: name the round's findings with --fix, --no-change, or --approve" >&2; exit 2; }
    [ -e "$FLAG" ] || die "the experiment is not enabled (no $FLAG); nothing logged"
    mkdir -p "$DATA" || die "cannot create $DATA"
    NOW=${FM_GATE_AB_NOW:-$(date +%s)}
    python3 -I - "$KEY" "$ARM" "$TASK" "$ROUND" "$NOW" "$DIGEST" "${ARGS[@]}" >> "$LOG" <<'PY' || { [ $? -ne 2 ] || exit 2; die "cannot append to $LOG"; }
import json, sys
key, arm, task, rnd, now, digest = sys.argv[1:7]
rest = sys.argv[7:]
run, step = key[3:].split("-", 1)
findings, seen = [], set()
for action, ids in zip(rest[0::2], rest[1::2]):
    for fid in (i.strip() for i in ids.split(",")):
        if not fid or fid in seen:
            print("error: empty or repeated finding id in '%s'" % ids, file=sys.stderr)
            sys.exit(2)
        seen.add(fid)
        findings.append({"id": fid, "action": action})
rec = {"schema": "fm-gate-ab.v1", "key": key, "arm": arm, "task": task, "run": run, "step": step,
       "round": int(rnd), "findings": findings, "at": int(now)}
if digest:
    rec["digest"] = digest
print(json.dumps(rec, sort_keys=True))
PY
    printf 'logged: %s decision for %s round %s in %s\n' "$ARM" "$KEY" "$ROUND" "$LOG"
    ;;

  report)
    BASE_DAYS=30; SINCE=''; TRANSCRIPTS=''
    while [ $# -gt 0 ]; do
      case "$1" in
        --baseline-days|--since|--transcripts)
          [ $# -ge 2 ] || { echo "error: $1 requires a value" >&2; exit 2; } ;;
      esac
      case "$1" in
        --baseline-days) BASE_DAYS=$2; shift 2 ;;
        --since) SINCE=$2; shift 2 ;;
        --transcripts) TRANSCRIPTS=$2; shift 2 ;;
        *) echo "error: unknown argument '$1'" >&2; exit 2 ;;
      esac
    done
    case "$BASE_DAYS" in ''|*[!0-9]*) echo "error: --baseline-days takes a number" >&2; exit 2 ;; esac
    case "$SINCE" in *[!0-9]*) echo "error: --since takes an epoch" >&2; exit 2 ;; esac
    if [ -z "$SINCE" ]; then
      [ -e "$FLAG" ] || die "the experiment is not enabled (no $FLAG); pass --since <epoch> to report on a past one"
      SINCE=$(python3 -I -c 'import os, sys; print(int(os.stat(sys.argv[1]).st_mtime))' "$FLAG") || die "cannot read $FLAG"
    fi
    if [ -z "$TRANSCRIPTS" ]; then
      TRANSCRIPTS=${FM_CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}/$(printf '%s' "$FM_HOME" | tr '/.' '--')
    fi
    DB=$(fm_nm_state_db "$FM_HOME")
    NOW=${FM_GATE_AB_NOW:-$(date +%s)}
    python3 -I - "$DB" "$LOG" "$DATA" "$STATE" "$TRANSCRIPTS" "$SINCE" "$BASE_DAYS" "$NOW" "$SCRIPT_DIR/fm-classify-lib.sh" <<'PY'
import datetime, glob, json, os, re, sqlite3, statistics, subprocess, sys
from contextlib import closing
from pathlib import Path

db_path, log_path, data, state, transcripts, since, base_days, now, classify = sys.argv[1:]
since, base_days, now = int(since), int(base_days), int(now)


def die(msg):
    print("error: " + msg, file=sys.stderr)
    sys.exit(1)


REQUIRED = {
    "runs": {"id"},
    "step_results": {"id", "run_id", "step_name", "completed_at"},
    "step_rounds": {"step_result_id", "round", "selected_finding_ids", "user_findings_json",
                    "selection_source", "reviewed_head_sha", "created_at"},
}
if not os.path.isfile(db_path):
    die("no-mistakes state database not found at " + db_path)
try:
    db = sqlite3.connect(Path(db_path).as_uri() + "?mode=ro", uri=True, timeout=30)
except sqlite3.Error as e:
    die("cannot open the no-mistakes state database: %s" % e)
with closing(db):
    for table, cols in REQUIRED.items():
        have = {r[1] for r in db.execute("PRAGMA table_info(%s)" % table)}
        if not have:
            die("no-mistakes state schema drift: table %s is missing" % table)
        if cols - have:
            die("no-mistakes state schema drift: %s lacks %s" % (table, ", ".join(sorted(cols - have))))
    steps = {}  # (run, step) -> {completed, rounds: {n: (created, selected, source)}}
    for sid, run, step, done in db.execute("SELECT id, run_id, step_name, completed_at FROM step_results"):
        steps[(run, step)] = {"id": sid, "completed": done, "rounds": {}}
    by_id = {v["id"]: v for v in steps.values()}
    for sid, rnd, sel, src, created in db.execute(
            "SELECT step_result_id, round, selected_finding_ids, selection_source, created_at FROM step_rounds"):
        try:
            ids = json.loads(sel) if sel else []
            if not isinstance(ids, list):
                raise ValueError
        except ValueError:
            die("no-mistakes state schema drift: selected_finding_ids is not a JSON list (round %s)" % rnd)
        if sid in by_id:
            by_id[sid]["rounds"][rnd] = (created, ids, src or "")


def read_jsonl(path):
    out = []
    if not os.path.isfile(path):
        return out
    with open(path) as fh:
        for n, line in enumerate(fh, 1):
            if not line.strip():
                continue
            try:
                out.append(json.loads(line))
            except ValueError:
                die("unreadable line %d in %s" % (n, path))
    return out


ab = read_jsonl(log_path)
helper_records = [r for p in glob.glob(os.path.join(data, "*", "gate-decisions.jsonl")) for r in read_jsonl(p)]
helper_seen = {(r.get("run"), r.get("step"), r.get("round")) for r in helper_records}
helper_seen |= {(r["run"], r["step"], r["round"]) for r in ab if r.get("arm") == "helper"}

decisions = []
for r in ab:
    if r.get("arm") in ("helper", "manual") and r.get("at", 0) >= since:
        decisions.append({"arm": r["arm"], "key": r["key"], "task": r.get("task"), "run": r["run"],
                          "step": r["step"], "round": r["round"], "at": r["at"],
                          "ids": [f["id"] for f in r.get("findings", [])], "digest": r.get("digest", "")})
logged = {(d["run"], d["step"], d["round"]) for d in decisions}
for (run, step), s in steps.items():
    for rnd, (created, ids, src) in s["rounds"].items():
        if src == "user" and ids and created is not None and since - base_days * 86400 <= created < since \
                and (run, step, rnd) not in helper_seen and (run, step, rnd) not in logged:
            decisions.append({"arm": "baseline", "key": "nm-%s-%s" % (run, step), "task": None, "run": run,
                              "step": step, "round": rnd, "at": None, "ids": ids, "digest": ""})

status_files = sorted(glob.glob(os.path.join(state, "*.status")))
history = {}
raw = []
for p in status_files:
    task = os.path.basename(p)[:-len(".status")]
    history[task] = []
    with open(p, errors="replace") as fh:
        raw.extend(task + "\t" + line.rstrip("\n") + "\n" for line in fh)
parsed = subprocess.run(["bash", "-c", r'''
. "$1"
while IFS=$(printf '\t') read -r task line; do
  epoch=$(status_line_at_epoch "$line") || epoch=''
  verb=$(status_line_verb "$line")
  key=$(_fm_decision_key "$line" '') || key=''
  printf '%s\t%s\t%s\t%s\t%s\n' "$task" "$epoch" "$verb" "$key" "$line"
done
''', "fm-gate-ab", classify], input="".join(raw), text=True, capture_output=True, check=True)
for line in parsed.stdout.splitlines():
    task, at, verb, key, text = line.split("\t", 4)
    history[task].append((verb, int(at) if at else None, key, text))

tasks_by_key = {}
for task, lines in history.items():
    for verb, at, key, text in lines:
        if key:
            tasks_by_key.setdefault(key, set()).add(task)
for r in ab + helper_records:
    if r.get("key") and r.get("task"):
        tasks_by_key.setdefault(r["key"], set()).add(r["task"])
for r in read_jsonl(os.path.join(state, "fleet-ledger.jsonl")):
    if r.get("event") == "task.status" and r.get("key") and r.get("task"):
        tasks_by_key.setdefault(r["key"], set()).add(r["task"])


PROBLEM = re.compile(r"respond.*(reject|refus|malform|invalid|unknown|error|usage|unrecogni|unexpected)"
                     r"|(reject|refus|malform|invalid|unknown|error|usage|unrecogni|unexpected).*respond", re.I)
for d in decisions:
    if d["task"] is None:
        tasks = tasks_by_key.get(d["key"], set())
        if len(tasks) == 1:
            d["task"] = next(iter(tasks))
decisions = [d for d in decisions if d["arm"] != "baseline" or d["task"] is not None]


def round_bounds(d):
    s = steps.get((d["run"], d["step"]))
    if not s or d["round"] not in s["rounds"]:
        return None, None
    created = s["rounds"][d["round"]][0]
    later = [v[0] for n, v in sorted(s["rounds"].items()) if n > d["round"] and v[0] is not None]
    return created, later[0] if later else (s["completed"] or now)

# Transcript turns holding the sending call.
needles = {}
for d in decisions:
    if d["arm"] == "helper" and d["digest"]:
        needles.setdefault("--confirm " + d["digest"], []).append(d)
    else:
        needles.setdefault(d["key"], []).append(d)


def is_turn_start(e):
    if e.get("type") != "user" or e.get("isSidechain"):
        return False
    c = (e.get("message") or {}).get("content")
    return not (isinstance(c, list) and any(isinstance(b, dict) and b.get("type") == "tool_result" for b in c))


def event_epoch(e):
    try:
        return datetime.datetime.fromisoformat((e.get("timestamp") or "").replace("Z", "+00:00")).timestamp()
    except (KeyError, ValueError, TypeError):
        return None


def sending_calls(e, needle, is_digest, task):
    if e.get("type") != "assistant":
        return
    for b in (e.get("message") or {}).get("content") or []:
        if isinstance(b, dict) and b.get("type") == "tool_use":
            cmd = json.dumps(b.get("input") or {})
            if needle in cmd and task and task in cmd and ("fm-gate-decide.sh" if is_digest else "fm-send.sh") in cmd:
                yield b.get("id")


def delivered(result):
    text = json.dumps(result.get("content", ""))
    if "recorded as delivered-unconfirmed" in text or "error: the answer was delivered to " in text:
        return True
    return not (result.get("is_error") or re.search(r"error:|Exit code:?\s*[1-9]", text, re.I))


def turn_usage(entries, at):
    s = at
    while s > 0 and not is_turn_start(entries[s]):
        s -= 1
    msgs = {}
    for e in entries[s + 1:]:
        if is_turn_start(e):
            break
        m = e.get("message") or {}
        if e.get("type") == "assistant" and isinstance(m.get("usage"), dict):
            msgs[m.get("id") or id(e)] = m["usage"]
    tot = {"out": 0, "all": 0}
    for u in msgs.values():
        o = u.get("output_tokens", 0) or 0
        tot["out"] += o
        tot["all"] += o + (u.get("input_tokens", 0) or 0) + (u.get("cache_creation_input_tokens", 0) or 0)
    return tot


tokens = {}  # id(decision) -> usage
candidates = {}
if needles and os.path.isdir(transcripts):
    for path in sorted(glob.glob(os.path.join(transcripts, "*.jsonl"))):
        with open(path, errors="replace") as fh:
            raw = fh.readlines()
        hit = [n for n in needles if any(n in l for l in raw)]
        if not hit:
            continue
        entries = []
        for l in raw:
            try:
                entries.append(json.loads(l))
            except ValueError:
                entries.append({})
        results = {}
        for e in entries:
            if e.get("type") == "user":
                for b in (e.get("message") or {}).get("content") or []:
                    if isinstance(b, dict) and b.get("type") == "tool_result":
                        results[b.get("tool_use_id")] = b
        for n in hit:
            for d in needles[n]:
                start, end = round_bounds(d)
                if start is None:
                    continue
                for i, e in enumerate(entries):
                    at = event_epoch(e)
                    if at is None or not start <= at < end or (d["at"] is not None and at >= d["at"] + 1):
                        continue
                    for call in sending_calls(e, n, n.startswith("--confirm "), d["task"]):
                        if call in results and delivered(results[call]):
                            candidates.setdefault(id(d), []).append((at, turn_usage(entries, i)))
for d in decisions:
    matches = candidates.get(id(d), [])
    if d["at"] is not None and matches:
        latest = max(at for at, _ in matches)
        matches = [(at, usage) for at, usage in matches if at == latest]
    if len(matches) == 1:
        tokens[id(d)] = matches[0][1]

# Per-decision measures.
for d in decisions:
    s = steps.get((d["run"], d["step"]))
    d["m"] = {}
    if not s or d["round"] not in s["rounds"]:
        d["m"]["unmatched"] = True
        continue
    later = {n: v for n, v in s["rounds"].items() if n > d["round"]}
    d["m"]["extra_rounds"] = sum(1 for v in later.values() if v[1])
    d["m"]["reselected"] = len({i for v in later.values() for i in v[1]} & set(d["ids"]))
    start, end = round_bounds(d)
    lines = history.get(d["task"])
    if lines is not None and start is not None:
        parks = [at for st, at, key, line in lines if st == "needs-decision" and key == d["key"]
                 and at is not None and start <= at < end and (d["at"] is None or at <= d["at"])]
        if parks and s["completed"]:
            d["m"]["to_done"] = s["completed"] - min(parks)
        if not any(at is None and st in ("blocked", "failed") and PROBLEM.search(line)
                   for st, at, key, line in lines):
            d["m"]["problems"] = sum(1 for st, at, key, line in lines
                                     if st in ("blocked", "failed") and at is not None
                                     and start <= at < end and PROBLEM.search(line))
    if id(d) in tokens:
        d["m"]["tok_out"] = tokens[id(d)]["out"]
        d["m"]["tok_all"] = tokens[id(d)]["all"]


def cell(rows, key, fmt="%.0f", agg="mean"):
    vals = [r["m"][key] for r in rows if key in r["m"]]
    if not vals:
        return "-"
    v = statistics.mean(vals) if agg == "mean" else statistics.median(vals)
    return (fmt % v) + " (n=%d)" % len(vals)


cols = [("arm", None), ("decisions", None), ("tok out", ("tok_out", "%.0f", "mean")),
        ("tok total", ("tok_all", "%.0f", "mean")), ("extra rounds", ("extra_rounds", "%.2f", "mean")),
        ("re-selected", ("reselected", "%.2f", "mean")), ("respond lines", ("problems", "%.2f", "mean")),
        ("park>done s", ("to_done", "%.0f", "median"))]
table = [[c[0] for c in cols]]
for arm in ("helper", "manual", "baseline"):
    rows = [d for d in decisions if d["arm"] == arm]
    line = [arm, str(len(rows))]
    for _, spec in cols[2:]:
        line.append(cell(rows, *spec))
    table.append(line)
widths = [max(len(r[i]) for r in table) for i in range(len(cols))]
print("gate decision A/B - experiment since epoch %d, baseline %d days before it" % (since, base_days))
print("mean per decision; park>done is a median; (n=) is the decisions with that measure available")
for r in table:
    print("  ".join(c.ljust(widths[i]) for i, c in enumerate(r)).rstrip())
unmatched = sum(1 for d in decisions if d["m"].get("unmatched"))
print("decisions with no matching no-mistakes round: %d" % unmatched)
print("Descriptive only: samples are small and unpaired, and no significance is claimed.")
print("Baseline holds fix decisions only (selection rows); tokens cover the whole turn that sent the decision.")
PY
    ;;
esac
