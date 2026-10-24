#!/usr/bin/env bash
# fm-attention.sh - read-only list of the decisions waiting on the captain,
# newest first, for an external reader such as Quarterdeck or Cadence.
#
# Usage: fm-attention.sh --json
#
# docs/fleet-ledger.md#open-decisions-for-outside-readers owns the
# fm-attention.v1 output schema and ordering contract.
# It reads bin/fm-fleet-snapshot.sh --local and state/fleet-ledger.jsonl and
# stores nothing.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LEDGER="$STATE/fleet-ledger.jsonl"

usage() {
  cat <<'EOF'
usage: fm-attention.sh --json

Print the decisions waiting on the captain, newest first, as JSON
(schema fm-attention.v1). Read-only: nothing is stored.
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --json) [ "$#" -eq 1 ] || { usage >&2; exit 2; } ;;
  *) usage >&2; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || { echo "fm-attention: jq not found" >&2; exit 1; }

SNAPSHOT=$("$SCRIPT_DIR/fm-fleet-snapshot.sh" --local) || exit $?

LEDGER_JSON='[]'
if [ -f "$LEDGER" ] && [ ! -L "$LEDGER" ] && [ -r "$LEDGER" ]; then
  # Tolerate a torn or foreign line: an unreadable record is skipped, never fatal.
  LEDGER_JSON=$(jq -R -c 'fromjson? | select(type == "object" and (.ts | type) == "number")' "$LEDGER" 2>/dev/null | jq -s -c '.') || LEDGER_JSON='[]'
  [ -n "$LEDGER_JSON" ] || LEDGER_JSON='[]'
fi

printf '%s\n%s\n' "$SNAPSHOT" "$LEDGER_JSON" | jq -s '
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
  | {schema: "fm-attention.v1",
     generated: .generated,
     open_decisions:
       ($rows
        | sort_by(if .touched == null then [1, 0] else [0, -.touched] end)
        | map({task, home, title, kind}
              + (if .kind == "keyed" then {key} else {} end)
              + {reason, bucket,
                 opened_at: (if .opened == null then null else (.opened | iso) end),
                 opened_precision: .precision,
                 last_touched_at: (if .touched == null then null else (.touched | iso) end)}))}'
