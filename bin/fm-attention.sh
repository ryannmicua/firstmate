#!/usr/bin/env bash
# fm-attention.sh - read-only list of the decisions waiting on the captain,
# newest first, plus this session's activity and the in-flight items, for an
# external reader such as Quarterdeck or Cadence.
#
# Usage: fm-attention.sh --json
#
# docs/fleet-ledger.md#open-decisions-for-outside-readers owns the
# fm-attention.v1 output schema, ordering, and session-start contract.
# It reads bin/fm-fleet-snapshot.sh --local, state/fleet-ledger.jsonl, and the
# modification times of state/.lock and state/.lock-session,
# and stores nothing.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LEDGER="$STATE/fleet-ledger.jsonl"

usage() {
  cat <<'EOF'
usage: fm-attention.sh --json

Print the decisions waiting on the captain, this session's activity (both
newest first), and the in-flight items, as JSON (schema fm-attention.v1).
Read-only: nothing is stored.
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --json) [ "$#" -eq 1 ] || { usage >&2; exit 2; } ;;
  *) usage >&2; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || { echo "fm-attention: jq not found" >&2; exit 1; }

# shellcheck source=bin/fm-lock-lib.sh
. "$SCRIPT_DIR/fm-lock-lib.sh"

SNAPSHOT=$("$SCRIPT_DIR/fm-fleet-snapshot.sh" --local) || exit $?

SESSION_START=null
SESSION_SOURCE=null
for pair in session_identity:.lock-session session_lock:.lock; do
  path="$STATE/${pair#*:}"
  [ -f "$path" ] && [ ! -L "$path" ] || continue
  mtime=$(fm_lock_path_mtime "$path") || continue
  case "$mtime" in ''|*[!0-9]*) continue ;; esac
  SESSION_START=$mtime
  SESSION_SOURCE="\"${pair%%:*}\""
  break
done

LEDGER_JSON='[]'
if [ -f "$LEDGER" ] && [ ! -L "$LEDGER" ] && [ -r "$LEDGER" ]; then
  # Tolerate a torn or foreign line: an unreadable record is skipped, never fatal.
  LEDGER_JSON=$(jq -R -c 'fromjson? | select(type == "object" and (.ts | type) == "number")' "$LEDGER" 2>/dev/null | jq -s -c '.') || LEDGER_JSON='[]'
  [ -n "$LEDGER_JSON" ] || LEDGER_JSON='[]'
fi

printf '%s\n%s\n' "$SNAPSHOT" "$LEDGER_JSON" | jq -s \
  --argjson session_start "$SESSION_START" --argjson session_source "$SESSION_SOURCE" '
  .[0] as $snapshot | .[1] as $ledger | $snapshot |
  def iso: floor | todate;
  def trunc($n): tostring | gsub("\\s+"; " ") | if length > $n then .[:$n] + "…" else . end;
  def stamp_epoch($s):
    if ($s | type) != "string" then null
    elif ($s | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) then (try ($s | fromdateiso8601) catch null)
    else null end;
  def day_epoch($s):
    if ($s | type) != "string" then null
    elif ($s | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")) then (try (($s + "T00:00:00Z") | fromdateiso8601) catch null)
    else null end;
  def newest($a; $b): [$a, $b] | map(select(. != null)) | if length == 0 then null else max end;
  def ledger_ts($task; $events):
    [ $ledger[] | select(.task == $task and ((.event) as $e | $events | index($e)) != null)
      | .ts ] | if length == 0 then null else max end;
  ([ .backlog.records[]?
     | select(.structured and .hold_bucket != null)
     | (stamp_epoch(.hold_set)) as $set
     | (day_epoch(.hold_set)) as $day
     | ($set // $day // day_epoch(.since)) as $opened
     | {task: .id, home: "main", title: (.title | trunc(160)), kind: "captain_hold",
        reason: ((.hold_reason // null) | if . == null then null else trunc(160) end),
        bucket: .hold_bucket,
        opened: $opened,
        precision: (if $set != null then "second" elif $opened != null then "day" else null end),
        touched: newest($opened; ledger_ts(.id; ["captain.held", "captain.deferred"]))} ]
   + [ .tasks[]? as $t | ($t.hints.open_decisions // [])[]
       | (.opened_epoch // null) as $opened
       | {task: $t.id, home: "main", title: (($t.backlog.title // $t.id) | trunc(160)), kind: "keyed",
          key: .key, reason: (.summary | trunc(160)), bucket: null,
          opened: $opened,
          precision: (if $opened != null then "second" else null end),
          touched: $opened} ]) as $rows
  | ([ .backlog.records[]? | select(.id != null) | {key: .id, value: .} ] | from_entries) as $records
  | ([ .tasks[]? | {key: .id, value: .} ] | from_entries) as $tasks
  | (reduce ($ledger[] | select((.task | type) == "string" and (.pr | type) == "string")) as $e
       ({}; .[$e.task] = $e.pr)) as $ledger_prs
  | def title_of($id): (($records[$id].title // $tasks[$id].backlog.title // $id) | trunc(160));
    def pr_of($id; $event_pr): $tasks[$id].pr.url // $event_pr // $ledger_prs[$id] // $records[$id].pr_url // null;
    def activity_line($e; $title):
      if $e.event == "task.dispatched" then "Started: \($title)"
      elif $e.event == "task.pr_ready" then "PR ready: \($title)"
      elif $e.event == "task.merged" then (if $e.via == "local" then "Landed locally: \($title)" else "Merged: \($title)" end)
      elif $e.event == "task.cleaned_up" then "Cleaned up: \($title)"
      elif $e.event == "task.status" then
        {"failed": "Failed: ", "blocked": "Blocked: ", "needs-decision": "Needs your decision: ", "resolved": "Resolved: ", "done": "Worker finished: "}[$e.state] + $title
      elif $e.event == "captain.held" then "Waiting on you: \($title)"
      elif $e.event == "captain.deferred" then "Deferred to \($e.until // "a later date"): \($title)"
      elif $e.event == "captain.answered" then
        {"done": "You answered: ", "release": "You answered and kept it open: ", "reconciled": "Closed as moot: "}[$e.mode] + $title
      else null end;
    ($session_start // ((now | floor) - 86400)) as $since
  | ([ $ledger | to_entries[]
       | .key as $i | .value
       | select(.ts >= $since and (.task | type) == "string")
       | select(.event != "task.status" or (.state == "failed" or .state == "blocked" or .state == "needs-decision" or .state == "resolved" or .state == "done"))
       | select(.event != "captain.answered" or (.mode == "done" or .mode == "release" or .mode == "reconciled"))
       | . as $e | title_of($e.task) as $title | activity_line($e; $title) as $line
       | select($line != null)
       | {i: $i, record: $e, ts, task, event,
          state: (if .event == "task.status" then .state else null end),
          key: (.key // null), mode: (.mode // null), line: $line,
          detail: (if .event == "task.status" then ((.text // "") | trunc(160) | ltrimstr(" ")) else null end),
          pr: pr_of($e.task; (if (.pr | type) == "string" then .pr else null end))} ]
     | group_by(.record) | map(max_by(.i))
     | sort_by([-.ts, -.i])) as $activity
  | {schema: "fm-attention.v1",
     generated: .generated,
     session: {started_at: ($since | iso),
               source: ($session_source // "fallback_24h")},
     session_activity_total: ($activity | length),
     session_activity_truncated: (($activity | length) > 100),
     session_activity: ($activity[:100] | map({at: (.ts | iso), task, event, state, key, mode, line, detail, pr})),
     in_flight:
       [ .backlog.records[]? | select(.state == "in_flight" and .id != null)
         | . as $r | $tasks[$r.id] as $t
         | {task: $r.id, title: ($r.title | trunc(160)), repo: ($r.repo // null),
            kind: ($r.kind // $t.kind // null),
            worker: (if $t == null then null else ($t.current_state.state // null) end),
            last_event: (($t.paths.status_log.last_event.raw // "") | if . == "" then null else trunc(160) end),
            pr: pr_of($r.id; null)} ],
     open_decisions:
       ($rows
        | sort_by(if .touched == null then [1, 0] else [0, -.touched] end)
        | map({task, home, title, kind}
              + (if .kind == "keyed" then {key} else {} end)
              + {reason, bucket,
                 opened_at: (if .opened == null then null else (.opened | iso) end),
                 opened_precision: .precision,
                 last_touched_at: (if .touched == null then null else (.touched | iso) end)}))}'
