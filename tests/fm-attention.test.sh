#!/usr/bin/env bash
# Behavior tests for the captain attention read (bin/fm-attention.sh) and the
# captain.* fleet ledger events bin/fm-captain-hold.sh records for it. The holds
# are made through the real script and tasks-axi; docs/fleet-ledger.md owns the
# event contract.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ATTENTION="$ROOT/bin/fm-attention.sh"
TMP_ROOT=$(fm_test_tmproot fm-attention)
TASKS_AXI_BIN=$(command -v tasks-axi || true)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

make_home() {  # <name> <on|off>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  fm_test_tasks_toml "$home/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  [ "$2" = off ] || : > "$home/config/fleet-ledger"
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  printf '%s\n' "$home"
}

run_captain() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-captain-hold.sh" "$@"
}

run_attention() {  # <home> [args]
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" "$ATTENTION" "${@:---json}"
}

ledger_events() {  # <home> <jq-expression>
  jq -r -c "$2" "$1/state/fleet-ledger.jsonl" 2>/dev/null | paste -sd' ' -
}

hold_at() {  # <home> <id> <utc-stamp>
  FM_CAPTAIN_HOLD_NOW=$3 run_captain "$1" hold "$2" --title "Call $2" \
    --reason "captain must decide $2" --repo sample >/dev/null \
    || fail "could not hold $2"
}

test_hold_answer_release_and_defer_are_recorded() {
  local home answer
  home=$(make_home ledger-on on)
  answer="$home/answer.txt"
  printf 'Use the first option.\n' > "$answer"
  hold_at "$home" asked 2026-07-01T10:00:00Z
  FM_CAPTAIN_HOLD_NOW=2026-07-01T11:00:00Z run_captain "$home" hold deferred --title "Call deferred" \
    --reason "revisit later" --repo sample --until 2026-12-01 >/dev/null || fail "could not defer"
  hold_at "$home" released 2026-07-01T12:00:00Z
  run_captain "$home" answer asked --decision-file "$answer" >/dev/null || fail "could not answer"
  run_captain "$home" answer released --decision-file "$answer" --release >/dev/null || fail "could not release"
  assert_equals 'captain.held:asked captain.deferred:deferred captain.held:released captain.answered:asked captain.answered:released' \
    "$(ledger_events "$home" 'select(.event | startswith("captain.")) | "\(.event):\(.task)"')" \
    "captain events in write order"
  assert_equals '2026-12-01' "$(ledger_events "$home" 'select(.event == "captain.deferred") | .until')" \
    "deferred date"
  assert_equals 'done release' "$(ledger_events "$home" 'select(.event == "captain.answered") | .mode')" \
    "answer modes"
  pass "hold, deferral, answer, and release each write one captain event"
}

test_reconcile_is_recorded() {
  local home evidence
  home=$(make_home ledger-reconcile on)
  evidence="$home/evidence.txt"
  printf 'The question is moot: the work shipped.\n' > "$evidence"
  hold_at "$home" moot 2026-07-01T10:00:00Z
  run_captain "$home" bind board-source >/dev/null || fail "could not bind"
  printf 'moot\n' | run_captain "$home" reconcile-requests --source-id board-source \
    --source "captured board result" >/dev/null || fail "could not request reconcile"
  run_captain "$home" reconcile close moot --evidence-file "$evidence" >/dev/null \
    || fail "could not reconcile"
  assert_equals 'captain.held:moot captain.answered:moot' \
    "$(ledger_events "$home" 'select(.event | startswith("captain.")) | "\(.event):\(.task)"')" \
    "events around a reconcile"
  assert_equals 'reconciled' "$(ledger_events "$home" 'select(.event == "captain.answered") | .mode')" \
    "reconcile mode"
  pass "a moot call closed by reconciliation records captain.answered with mode reconciled"
}

test_flag_off_writes_nothing() {
  local home leftovers
  home=$(make_home ledger-off off)
  printf 'ok\n' > "$home/answer.txt"
  hold_at "$home" quiet 2026-07-01T10:00:00Z
  run_captain "$home" answer quiet --decision-file "$home/answer.txt" >/dev/null || fail "could not answer"
  leftovers=$(cd "$home/state" && find . -name '*fleet-ledger*')
  assert_equals "" "$leftovers" "ledger files with the flag absent"
  pass "flag off: holds and answers leave no ledger file or lock"
}

test_ledger_command_rejects_bad_captain_events() {
  local home
  home=$(make_home ledger-usage on)
  for args in "captain_answered t maybe" "captain_deferred t" "captain_held" "captain_held bad/id"; do
    # shellcheck disable=SC2086
    FM_HOME="$home" "$ROOT/bin/fm-fleet-ledger.sh" $args >/dev/null 2>&1 \
      && fail "accepted: $args"
  done
  [ ! -s "$home/state/fleet-ledger.jsonl" ] || fail "a rejected event wrote a record"
  pass "the ledger writer refuses malformed captain events without writing"
}

test_open_decisions_are_newest_first() {
  local home out epoch
  home=$(make_home order off)
  hold_at "$home" older 2026-07-01T10:00:00Z
  hold_at "$home" newer 2026-07-03T09:30:15Z
  cat >> "$home/data/backlog.md" <<'EOF'
EOF
  sed -i 's/^## Done$/- [ ] legacy-call - Legacy call (repo: sample) (kind: captain) (hold: old question) (hold-kind: captain) (since 2026-07-02)\n\n## Done/' "$home/data/backlog.md"
  epoch=$(date -u -d 2026-07-02T12:00:00Z +%s)
  mkdir -p "$home/mate-home"
  fm_write_meta "$home/state/mate.meta" \
    "window=firstmate:fm-mate" "worktree=$home/mate-home" "project=$home/mate-home" \
    "harness=codex" "kind=secondmate" "mode=secondmate" "home=$home/mate-home" "projects=alpha"
  printf 'needs-decision [key=api-shape] [at=%s]: choose the API shape\n' "$epoch" > "$home/state/mate.status"
  printf 'needs-decision [key=unstamped]: no time on this line\n' >> "$home/state/mate.status"
  out=$(run_attention "$home") || fail "fm-attention failed: $out"
  printf '%s' "$out" | jq -e '.schema == "fm-attention.v1" and (.generated | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$"))
    and (keys | sort) == ["generated", "in_flight", "open_decisions", "schema", "session", "session_activity", "session_activity_total", "session_activity_truncated"]' >/dev/null \
    || fail "unexpected envelope: $out"
  assert_equals 'newer api-shape legacy-call older unstamped' \
    "$(printf '%s' "$out" | jq -r '[.open_decisions[] | (.key // .task)] | join(" ")')" \
    "newest-first order, undated last"
  printf '%s' "$out" | jq -e '
    (.open_decisions[] | select(.task == "newer"))
      | .kind == "captain_hold" and .home == "main" and .opened_at == "2026-07-03T09:30:15Z"
        and .opened_precision == "second" and .last_touched_at == .opened_at and .bucket == "aged"
        and .reason == "captain must decide newer"' >/dev/null || fail "captain hold row wrong: $out"
  printf '%s' "$out" | jq -e '
    (.open_decisions[] | select(.task == "legacy-call"))
      | .opened_at == "2026-07-02T00:00:00Z" and .opened_precision == "day"' >/dev/null \
    || fail "legacy hold must fall back to the day it was filed: $out"
  printf '%s' "$out" | jq -e '
    (.open_decisions[] | select(.key == "api-shape"))
      | .kind == "keyed" and .task == "mate" and .opened_at == "2026-07-02T12:00:00Z"
        and .opened_precision == "second" and .bucket == null' >/dev/null \
    || fail "keyed decision must carry its [at=] stamp: $out"
  printf '%s' "$out" | jq -e '
    (.open_decisions[] | select(.key == "unstamped"))
      | .opened_at == null and .opened_precision == null and .last_touched_at == null' >/dev/null \
    || fail "an unstamped keyed decision has no time: $out"
  pass "open decisions sort newest first with second, day, and unknown opened times"
}

test_ledger_events_move_last_touched() {
  local home out ts
  home=$(make_home touched on)
  hold_at "$home" first 2026-07-01T10:00:00Z
  hold_at "$home" second 2026-07-02T10:00:00Z
  # The ledger recorded both just now, at the real clock; place a later re-hold
  # of the older call an hour ahead of it.
  ts=$(( $(date +%s) + 3600 ))
  printf '{"v":1,"ts":%s,"event":"captain.held","task":"first"}\n' "$ts" >> "$home/state/fleet-ledger.jsonl"
  printf 'not json\n{"ts":"x"}\n' >> "$home/state/fleet-ledger.jsonl"
  out=$(run_attention "$home") || fail "fm-attention failed: $out"
  assert_equals "first" "$(printf '%s' "$out" | jq -r '.open_decisions[0].task')" \
    "a ledger event makes the call newest"
  printf '%s' "$out" | jq -e '
    (.open_decisions | map(select(.task == "first"))[0])
      | .opened_at == "2026-07-01T10:00:00Z"' >/dev/null || fail "opened_at must not move: $out"
  printf '%s' "$out" | jq -e --argjson ts "$ts" '(.open_decisions | map(select(.task == "first"))[0].last_touched_at | fromdateiso8601) == $ts' \
    >/dev/null || fail "last_touched_at must follow the ledger: $out"
  pass "ledger events raise last_touched_at while opened_at stays put, and torn ledger lines are skipped"
}

test_answered_call_is_not_open() {
  local home out
  home=$(make_home answered on)
  printf 'ok\n' > "$home/answer.txt"
  hold_at "$home" gone 2026-07-01T10:00:00Z
  hold_at "$home" stays 2026-07-02T10:00:00Z
  run_captain "$home" answer gone --decision-file "$home/answer.txt" >/dev/null || fail "could not answer"
  out=$(run_attention "$home") || fail "fm-attention failed: $out"
  assert_equals "stays" "$(printf '%s' "$out" | jq -r '[.open_decisions[].task] | join(" ")')" \
    "only the unanswered call remains"
  pass "an answered call leaves the open decisions"
}

test_read_is_side_effect_free_and_validates_arguments() {
  local home before after
  home=$(make_home readonly on)
  hold_at "$home" call 2026-07-01T10:00:00Z
  before=$(cd "$home" && find . -type f -exec cksum {} + | LC_ALL=C sort)
  run_attention "$home" >/dev/null || fail "fm-attention failed"
  after=$(cd "$home" && find . -type f -exec cksum {} + | LC_ALL=C sort)
  assert_equals "$before" "$after" "files after a read"
  run_attention "$home" >/dev/null 2>&1 && true
  PATH="$home/fakebin:$PATH" FM_HOME="$home" "$ATTENTION" >/dev/null 2>&1 && fail "ran without --json"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" "$ATTENTION" --json extra >/dev/null 2>&1 && fail "accepted an extra argument"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" "$ATTENTION" --help >/dev/null 2>&1 || fail "--help failed"
  pass "the read stores nothing and rejects unknown arguments"
}

test_date_only_hold_stamp() {
  local home out
  home=$(make_home day-stamp off)
  hold_at "$home" legacy-day 2026-01-01T10:00:00Z
  hold_at "$home" july-second 2026-07-02T10:00:00Z
  sed -i 's/Captain hold set: 2026-01-01T10:00:00Z/Captain hold set: 2026-07-03/' "$home/data/backlog.md"
  out=$(run_attention "$home") || fail "fm-attention failed: $out"
  printf '%s' "$out" | jq -e '.open_decisions[0]
    | .task == "legacy-day" and .opened_at == "2026-07-03T00:00:00Z"
      and .opened_precision == "day"' >/dev/null || fail "date-only hold stamp lost: $out"
  pass "a date-only hold stamp takes precedence over the filing date"
}

test_keyed_emission_order_with_large_delayed_ledger() {
  local home out
  home=$(make_home delayed on)
  mkdir -p "$home/mate-home"
  fm_write_meta "$home/state/mate.meta" \
    "window=firstmate:fm-mate" "worktree=$home/mate-home" "project=$home/mate-home" \
    "harness=codex" "kind=secondmate" "mode=secondmate" "home=$home/mate-home" "projects=alpha"
  cat > "$home/state/mate.status" <<'EOF'
needs-decision [key=pending-reply-old] [at=1783072800]: pending-reply-missed: choose old
needs-decision [key=new] [at=1783076400]: choose new
blocked [key=pending-reply-old] [at=1783080000]: unrelated stamped note
blocked [key=pending-reply-old]: unrelated unstamped note
needs-decision [key=unknown]: choose unknown
EOF
  jq -nc '[range(0;2048) | "x"] | join("") as $note
    | range(0;100) | {ts:(1783080000 + .),event:"task.status",task:"mate",
       state:"blocked",key:"pending-reply-old",note:$note}' > "$home/state/fleet-ledger.jsonl"
  printf '{"ts":1783090000,"event":"task.status","task":"mate","state":"needs-decision","key":"unknown"}\n' >> "$home/state/fleet-ledger.jsonl"
  [ "$(wc -c < "$home/state/fleet-ledger.jsonl")" -gt 131072 ] || fail "ledger fixture too small"
  out=$(run_attention "$home") || fail "fm-attention failed: $out"
  assert_equals 'new pending-reply-old unknown' \
    "$(printf '%s' "$out" | jq -r '[.open_decisions[].key] | join(" ")')" \
    "emission order survives delayed capture and rejected transitions"
  printf '%s' "$out" | jq -e 'all(.open_decisions[]; .last_touched_at == .opened_at)
    and (.open_decisions[] | select(.key == "pending-reply-old")
      | .opened_at == "2026-07-03T10:00:00Z")
    and (.open_decisions[] | select(.key == "unknown") | .opened_at == null)' >/dev/null \
    || fail "capture or rejected transition changed emission timestamps: $out"
  pass "large ledgers preserve source emission times and accepted opening transitions"
}

test_opening_timestamp_acceptance() {
  local home kind verb out
  home=$(make_home acceptance off)
  for kind in ship scout secondmate; do
    for verb in needs-decision blocked; do
      printf '%s [key=pending-reply-check] [at=100]: pending-reply-missed: choose\n' "$verb" > "$home/state/check.status"
      printf '%s [key=pending-reply-check] [at=200]: unrelated\n' "$verb" >> "$home/state/check.status"
      printf '%s [key=pending-reply-check]: unrelated\n' "$verb" >> "$home/state/check.status"
      out=$(bash -c '. "$1/bin/fm-classify-lib.sh"; status_open_decisions_at "$2" "$3"' \
        _ "$ROOT" "$home/state/check.status" "$kind")
      assert_equals "pending-reply-check"$'\t'"$verb"$'\t'"pending-reply-missed: choose"$'\t100' "$out" "accepted opening for $kind/$verb"
      printf '%s [key=pending-reply-check] [at=300]: pending-reply-missed: choose again\n' "$verb" >> "$home/state/check.status"
      out=$(bash -c '. "$1/bin/fm-classify-lib.sh"; status_open_decisions_at "$2" "$3"' \
        _ "$ROOT" "$home/state/check.status" "$kind")
      assert_equals "pending-reply-check"$'\t'"$verb"$'\t'"pending-reply-missed: choose again"$'\t300' "$out" "accepted update for $kind/$verb"
      printf 'resolved [key=pending-reply-check]: pending-reply-missed: answered\n' >> "$home/state/check.status"
      out=$(bash -c '. "$1/bin/fm-classify-lib.sh"; status_open_decisions_at "$2" "$3"' \
        _ "$ROOT" "$home/state/check.status" "$kind")
      assert_equals '' "$out" "resolved decision for $kind/$verb"
    done
  done
  pass "rejected openings preserve timestamps while accepted updates and resolutions still work"
}

test_rehold_recency() {
  local home until before out count
  for until in '' 2026-12-01 2026-01-01; do
    home=$(make_home "rehold-${until:-undated}" on)
    FM_CAPTAIN_HOLD_NOW=2026-07-01T10:00:00Z run_captain "$home" hold first \
      --title 'Call first' --reason 'choose (first)' --repo sample --until "$until" >/dev/null || fail "first hold failed"
    FM_CAPTAIN_HOLD_NOW=2026-07-01T11:00:00Z run_captain "$home" hold second \
      --title 'Call second' --reason 'choose second' --repo sample --until "$until" >/dev/null || fail "second hold failed"
    jq -c '.ts = (if .task == "first" then 1782900000 else 1782903600 end)' \
      "$home/state/fleet-ledger.jsonl" > "$home/ledger-times.jsonl"
    mv "$home/ledger-times.jsonl" "$home/state/fleet-ledger.jsonl"
    before=$(cat "$home/state/fleet-ledger.jsonl")
    FM_CAPTAIN_HOLD_NOW=2026-07-01T12:00:00Z run_captain "$home" hold first \
      --reason 'choose (first)' --until "$until" >/dev/null || fail "retry failed"
    assert_equals "$before" "$(cat "$home/state/fleet-ledger.jsonl")" "unchanged re-hold ledger/$until"
    out=$(run_attention "$home") || fail "attention failed"
    assert_equals 'second first' "$(printf '%s' "$out" | jq -r '[.open_decisions[].task] | join(" ")')" "retry ordering/$until"
    printf '%s' "$out" | jq -e '.open_decisions[] | select(.task == "first")
      | .opened_at == "2026-07-01T10:00:00Z" and .last_touched_at == .opened_at' >/dev/null \
      || fail "retry moved timestamps: $out"
    run_captain "$home" hold first --reason 'different (reason)' --until "$until" >/dev/null || fail "reason change failed"
    count=$(jq -s 'length' "$home/state/fleet-ledger.jsonl")
    assert_equals 3 "$count" "reason change emits once/$until"
    out=$(run_attention "$home") || fail "attention failed"
    assert_equals first "$(printf '%s' "$out" | jq -r '.open_decisions[0].task')" "changed reason moves recency/$until"
    run_captain "$home" hold first --reason 'different (reason)' --until 2027-01-01 >/dev/null || fail "date change failed"
    assert_equals 'captain.deferred:2027-01-01' \
      "$(tail -1 "$home/state/fleet-ledger.jsonl" | jq -r '.event + ":" + .until')" "date change event/$until"
    before=$(cat "$home/state/fleet-ledger.jsonl")
    run_captain "$home" hold first --reason 'different (reason)' --until 2027-01-01 >/dev/null || fail "dated retry failed"
    assert_equals "$before" "$(cat "$home/state/fleet-ledger.jsonl")" "dated retry ledger/$until"
    run_captain "$home" hold first --reason 'different (reason)' >/dev/null || fail "date removal failed"
    assert_equals captain.held "$(tail -1 "$home/state/fleet-ledger.jsonl" | jq -r '.event')" "date removal event/$until"
    assert_equals 5 "$(jq -s 'length' "$home/state/fleet-ledger.jsonl")" "only actual hold changes emit/$until"
  done
  pass "unchanged dated and undated re-holds preserve recency; reason and date changes emit events"
}

test_continuations_preserve_opening_timestamps() {
  local home kind verb out plain
  home=$(make_home continuation off)
  for kind in ship scout secondmate; do
    for verb in needs-decision blocked; do
      printf '%s [at=100]: need access\n %s\n %s [at=12:30]\n' "$verb" "$verb" "$verb" > "$home/state/check.status"
      out=$(bash -c '. "$1/bin/fm-classify-lib.sh"; status_open_decisions_at "$2" "$3"' \
        _ "$ROOT" "$home/state/check.status" "$kind")
      assert_equals "default"$'\t'"$verb"$'\tneed access\t100' "$out" "continuations/$kind/$verb"
      printf '%s [at=200]: need access\n' "$verb" >> "$home/state/check.status"
      out=$(bash -c '. "$1/bin/fm-classify-lib.sh"; status_open_decisions_at "$2" "$3"' \
        _ "$ROOT" "$home/state/check.status" "$kind")
      assert_equals "default"$'\t'"$verb"$'\tneed access\t200' "$out" "identical accepted opening/$kind/$verb"
      plain=$(bash -c '. "$1/bin/fm-classify-lib.sh"; status_open_decisions "$2" "$3"' \
        _ "$ROOT" "$home/state/check.status" "$kind")
      assert_equals "$plain" "${out%$'\t'*}" "three-column fold compatibility/$kind/$verb"
      printf 'resolved: answered\n' >> "$home/state/check.status"
      out=$(bash -c '. "$1/bin/fm-classify-lib.sh"; status_open_decisions_at "$2" "$3"' \
        _ "$ROOT" "$home/state/check.status" "$kind")
      assert_equals '' "$out" "resolution/$kind/$verb"
    done
  done
  pass "shared fold ignores continuations and timestamps accepted identical openings"
}

test_legacy_rehold_preserves_effective_date() {
  local home flag out before
  for flag in off on; do
    home=$(make_home "legacy-rehold-$flag" "$flag")
    cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

- [ ] legacy - Legacy call (repo: sample) (kind: captain) (hold: legacy question) (hold-kind: captain) (since 2026-01-01)
- [ ] stamped - Stamped call (repo: sample) (kind: captain) (hold: stamped question) (hold-kind: captain) (since 2026-01-02)
  Captain hold set: 2026-02-01T10:00:00Z

## Done
EOF
    before=$(run_attention "$home") || fail "legacy read failed"
    FM_CAPTAIN_HOLD_NOW=2026-03-01T10:00:00Z run_captain "$home" hold legacy \
      --reason 'legacy question' >/dev/null || fail "legacy re-hold failed"
    out=$(run_attention "$home") || fail "legacy retry read failed"
    assert_equals "$(printf '%s' "$before" | jq -c .open_decisions)" \
      "$(printf '%s' "$out" | jq -c .open_decisions)" "legacy retry recency/$flag"
    [ ! -s "$home/state/fleet-ledger.jsonl" ] || fail "unchanged legacy retry emitted an event"
  done
  pass "legacy re-holds retain their effective opening date with the ledger on or off"
}

test_attention_skips_secondmate_collection() {
  local home before after out directories
  home=$(make_home no-collection off)
  hold_at "$home" local-call 2026-07-01T10:00:00Z
  printf -- '- remote - Remote mate (host: sample-host; root: /remote/root; home: /remote/home; scope: fixture; projects: sample; added 2026-09-01)\n' > "$home/data/secondmates.md"
  fm_write_meta "$home/state/remote.meta" 'kind=secondmate' 'mode=secondmate' \
    'harness=codex' 'remote_host=sample-host' 'remote_root=/remote/root' 'home=/remote/home'
  printf 'needs-decision [key=remote-call] [at=1782907200]: choose remote option\n' > "$home/state/remote.status"
  cat > "$home/fakebin/ssh" <<'SH'
#!/usr/bin/env bash
exit 99
SH
  chmod +x "$home/fakebin/ssh"
  before=$(cd "$home" && find . -type f -exec cksum {} + | LC_ALL=C sort)
  directories=$(cd "$home" && find . | LC_ALL=C sort)
  out=$(run_attention "$home") || fail "attention required remote collection"
  after=$(cd "$home" && find . -type f -exec cksum {} + | LC_ALL=C sort)
  assert_equals "$before" "$after" "attention files with registered secondmate"
  assert_equals "$directories" "$(cd "$home" && find . | LC_ALL=C sort)" "attention created no cache directories"
  assert_equals 'remote-call local-call' \
    "$(printf '%s' "$out" | jq -r '[.open_decisions[] | (.key // .task)] | join(" ")')" "parent-side remote decision preserved"
  pass "attention retains parent-side decisions without secondmate cache writes"
}

test_attention_uses_configured_adapter() {
  local home out before after
  home=$(make_home adapter on)
  mv "$home/data/backlog.md" "$home/adapter.md"
  printf 'backend = "beads"\n[beads]\npath = "graph/.beads"\n' > "$home/.tasks.toml"
  cat > "$home/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
[ -z "${TASKS_AXI_FILE:-}" ] || exit 91
for arg in "$@"; do
  case "$arg" in --file|--file=*) exit 92 ;; esac
done
case "$1:${2:-}" in --version:*|*:--help) exec "$REAL_TASKS_AXI" "$@" ;; esac
[ -f "$PWD/adapter.md" ] || exit 93
exec "$REAL_TASKS_AXI" "$@" --backend markdown --file "$PWD/adapter.md"
SH
  chmod +x "$home/fakebin/tasks-axi"
  out=$(REAL_TASKS_AXI="$TASKS_AXI_BIN" run_attention "$home") || fail "empty adapter read failed"
  assert_equals 0 "$(printf '%s' "$out" | jq '.open_decisions | length')" "empty adapter inventory"
  hold_at "$home" adapter-call 2026-07-03T10:00:00Z
  FM_CAPTAIN_HOLD_NOW=2026-07-04T10:00:00Z run_captain "$home" hold dated-call \
    --title 'A "dated", call' --reason 'a reason (with punctuation)' --repo sample --until 2027-01-01 >/dev/null || fail "adapter deferral failed"
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" FM_HOME="$home" \
    "$ROOT/bin/fm-tasks-axi.sh" add blocker 'Blocking task' --repo sample >/dev/null || fail "adapter blocker add failed"
  hold_at "$home" blocked-call 2026-07-02T10:00:00Z
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" FM_HOME="$home" \
    "$ROOT/bin/fm-tasks-axi.sh" block blocked-call --by blocker >/dev/null || fail "adapter block failed"
  before=$(cksum "$home/adapter.md")
  out=$(REAL_TASKS_AXI="$TASKS_AXI_BIN" run_attention "$home") || fail "adapter attention failed"
  after=$(cksum "$home/adapter.md")
  assert_equals "$before" "$after" "adapter read is read-only"
  [ ! -e "$home/data/backlog.md" ] || fail "adapter read created a Markdown backlog"
  printf '%s' "$out" | jq -e '
    (.open_decisions | length) == 3
    and any(.open_decisions[]; .task == "blocked-call" and .bucket == "blocked")
    and any(.open_decisions[]; .task == "adapter-call" and .opened_at == "2026-07-03T10:00:00Z")
    and any(.open_decisions[]; .task == "dated-call" and .bucket == "dated"
      and .title == "A \"dated\", call" and .reason == "a reason (with punctuation)")' >/dev/null || fail "adapter holds missing: $out"
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" FM_HOME="$home" \
    "$ROOT/bin/fm-tasks-axi.sh" "done" blocker >/dev/null || fail "adapter blocker completion failed"
  out=$(REAL_TASKS_AXI="$TASKS_AXI_BIN" run_attention "$home") || fail "adapter reread failed"
  printf '%s' "$out" | jq -e 'any(.open_decisions[]; .task == "blocked-call" and .bucket == "aged")' >/dev/null \
    || fail "adapter completed blocker still blocks: $out"
  pass "attention reads the configured adapter without a Markdown backlog"
}

activity_home() {  # <name>: a home with one in-flight task and a ledger ending at 2026-07-01T10:00:00Z
  local home
  home=$(make_home "$1" on)
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

- [ ] fix-login - Fix the login page (repo: webapp) (kind: ship) (since 2026-07-01)
- [ ] queued-only - Nothing launched yet (repo: webapp) (kind: ship) (since 2026-07-01)

## Queued

## Done

- [x] old-task - Old finished work (repo: webapp) (kind: ship) (since 2026-06-01)
EOF
  # 1782900000 is 2026-07-01T10:00:00Z.
  cat > "$home/state/fleet-ledger.jsonl" <<'EOF'
{"v":1,"ts":1782890000,"event":"task.dispatched","task":"old-task","kind":"ship","project":"webapp","harness":"claude","model":null}
{"v":1,"ts":1782899000,"event":"task.dispatched","task":"fix-login","kind":"ship","project":"webapp","harness":"claude","model":null}
{"v":1,"ts":1782899100,"event":"task.status","task":"fix-login","state":"working","key":null,"text":" bug reproduced"}
{"v":1,"ts":1782899200,"event":"task.status","task":"fix-login","state":"needs-decision","key":"shape","text":" pick a  shape"}
not json at all
{"v":1,"ts":1782899300,"event":"task.status","task":"fix-login","state":"done","key":null,"text":" first try"}
{"v":1,"ts":1782899400,"event":"task.status","task":"fix-login","state":"done","key":null,"text":" PR https://example.test/acme/webapp/pull/7 checks green"}
{"v":1,"ts":1782899500,"event":"task.pr_ready","task":"fix-login","pr":"https://example.test/acme/webapp/pull/7"}
{"v":1,"ts":1782899600,"event":"captain.held","task":"old-task"}
{"v":1,"ts":1782899700,"event":"captain.answered","task":"old-task","mode":"done"}
{"v":1,"ts":1782899800,"event":"task.future_kind","task":"fix-login"}
{"v":1,"ts":1782899900,"event":"task.merged","task":"old-task","via":"local"}
{"v":1,"ts":1782900000,"event":"task.cleaned_up","task":"gone-task"}
EOF
  printf '%s\n' "$home"
}

test_session_activity_is_newest_first_and_distinct() {
  local home out
  home=$(activity_home activity)
  : > "$home/state/.lock"
  TZ=UTC touch -t 202607010920.00 "$home/state/.lock"  # 1782897600
  out=$(run_attention "$home") || fail "fm-attention failed: $out"
  printf '%s' "$out" | jq -e '.session == {started_at: "2026-07-01T09:20:00Z", source: "session_lock"}' >/dev/null \
    || fail "session start not read from the session lock: $out"
  assert_equals 'Cleaned up: gone-task|Landed locally: Old finished work|You answered: Old finished work|Waiting on you: Old finished work|PR ready: Fix the login page|Worker finished: Fix the login page|Worker finished: Fix the login page|Needs your decision: Fix the login page|Started: Fix the login page' \
    "$(printf '%s' "$out" | jq -r '[.session_activity[].line] | join("|")')" \
    "activity newest first, routine status and unknown events skipped, distinct transitions retained, earlier session excluded"
  printf '%s' "$out" | jq -e '
    (.session_activity[] | select(.event == "task.status" and .state == "done" and .detail != "first try"))
      | .at == "2026-07-01T09:50:00Z" and .task == "fix-login"
        and .detail == "PR https://example.test/acme/webapp/pull/7 checks green"
        and .pr == "https://example.test/acme/webapp/pull/7"' >/dev/null \
    || fail "the latest completion must carry the recorded PR: $out"
  printf '%s' "$out" | jq -e '
    (.session_activity[] | select(.event == "task.status" and .state == "needs-decision") | .detail == "pick a shape")
    and (.session_activity[] | select(.event == "task.dispatched") | .state == null and .detail == null)
    and (.session_activity[] | select(.task == "old-task") | .pr == null)' >/dev/null \
    || fail "activity item fields wrong: $out"
  printf '%s' "$out" | jq -e '
    [.in_flight[] | {task, title, repo, kind, worker, last_event, pr}] == [
      {task: "fix-login", title: "Fix the login page", repo: "webapp", kind: "ship", worker: null,
       last_event: null, pr: "https://example.test/acme/webapp/pull/7"},
      {task: "queued-only", title: "Nothing launched yet", repo: "webapp", kind: "ship", worker: null,
       last_event: null, pr: null}]' >/dev/null \
    || fail "in-flight items must come from the backlog with ledger PRs: $out"
  pass "session activity lists this session's ledger events newest first with plain lines, and in-flight items are structured"
}

test_in_flight_reports_the_worker_state() {
  local home out
  home=$(activity_home in-flight-worker)
  mkdir -p "$home/wt"
  fm_write_meta "$home/state/fix-login.meta" "window=firstmate:fm-fix-login" "worktree=$home/wt" \
    "project=$home/wt" "harness=claude" "kind=ship" "mode=no-mistakes"
  printf 'working [at=1782899100]: bug reproduced\n' > "$home/state/fix-login.status"
  out=$(run_attention "$home") || fail "fm-attention failed: $out"
  printf '%s' "$out" | jq -e '
    (.in_flight[] | select(.task == "fix-login"))
      | .last_event == "working [at=1782899100]: bug reproduced" and (.worker | type) == "string"' >/dev/null \
    || fail "a launched task must carry its worker state and last status line: $out"
  pass "an in-flight item with a live worker carries its state and last status line"
}

test_session_start_sources_and_fallback() {
  local home out now before_reanchor
  home=$(activity_home activity-sources)
  : > "$home/state/.lock"
  : > "$home/state/.session-start-complete"
  : > "$home/state/.lock-session"
  TZ=UTC touch -t 202607010920.00 "$home/state/.lock"
  TZ=UTC touch -t 202607011000.00 "$home/state/.session-start-complete"
  TZ=UTC touch -t 202607010945.00 "$home/state/.lock-session"  # 1782899100
  out=$(run_attention "$home") || fail "fm-attention failed: $out"
  printf '%s' "$out" | jq -e '.session == {started_at: "2026-07-01T09:45:00Z", source: "session_identity"}
    and ([.session_activity[].task] | index("fix-login")) != null
    and ([.session_activity[] | select(.event == "task.dispatched")] | length) == 0' >/dev/null \
    || fail "a later session identity change must start the session: $out"
  before_reanchor=$(printf '%s' "$out" | jq -c '{session, session_activity, session_activity_total, session_activity_truncated}')
  TZ=UTC touch -t 202607010955.00 "$home/state/.lock"
  out=$(run_attention "$home") || fail "fm-attention failed: $out"
  assert_equals "$before_reanchor" \
    "$(printf '%s' "$out" | jq -c '{session, session_activity, session_activity_total, session_activity_truncated}')" \
    "same-session re-anchor must preserve the identity boundary and all prior activity"
  rm -f "$home/state/.lock"
  out=$(run_attention "$home") || fail "fm-attention failed: $out"
  assert_equals "$before_reanchor" \
    "$(printf '%s' "$out" | jq -c '{session, session_activity, session_activity_total, session_activity_truncated}')" \
    "identity-only reads must preserve the session boundary and activity"
  : > "$home/state/.lock"
  TZ=UTC touch -t 202607010920.00 "$home/state/.lock"
  rm -f "$home/state/.lock-session"
  out=$(run_attention "$home") || fail "fm-attention failed: $out"
  printf '%s' "$out" | jq -e '.session == {started_at: "2026-07-01T09:20:00Z", source: "session_lock"}
    and any(.session_activity[]; .event == "task.dispatched" and .task == "fix-login")' >/dev/null \
    || fail "lock-only sessions must include events during startup: $out"
  rm -f "$home/state/.lock"

  now=$(date +%s)
  printf '{"v":1,"ts":%s,"event":"task.pr_ready","task":"fix-login","pr":"https://example.test/acme/webapp/pull/8"}\n' \
    "$((now - 3600))" >> "$home/state/fleet-ledger.jsonl"
  out=$(run_attention "$home") || fail "fm-attention failed: $out"
  printf '%s' "$out" | jq -e --argjson now "$now" '.session.source == "fallback_24h"
    and ((.session.started_at | fromdateiso8601) - ($now - 86400) | fabs) < 60
    and [.session_activity[] | {line, pr}] == [{line: "PR ready: Fix the login page", pr: "https://example.test/acme/webapp/pull/8"}]' >/dev/null \
    || fail "without a session record the window must be the last 24 hours: $out"
  pass "session boundaries include startup activity and the fallback is labeled as a rolling 24-hour window"
}

test_activity_preserves_decisions_and_reports_cap() {
  local home out
  home=$(activity_home activity-distinct)
  : > "$home/state/.lock"
  TZ=UTC touch -t 202607010920.00 "$home/state/.lock"
  cat >> "$home/state/fleet-ledger.jsonl" <<'EOF'
{"v":1,"ts":1782900010,"event":"task.status","task":"fix-login","state":"failed","text":"failed build"}
{"v":1,"ts":1782900020,"event":"task.status","task":"fix-login","state":"blocked","text":"waiting"}
{"v":1,"ts":1782900030,"event":"task.status","task":"fix-login","state":"resolved","text":"unblocked"}
{"v":1,"ts":1782900040,"event":"task.status","task":"fix-login","state":"needs-decision","key":"first","text":"choose"}
{"v":1,"ts":1782900040,"event":"task.status","task":"fix-login","state":"needs-decision","key":"second","text":"choose"}
{"v":1,"ts":1782900040,"event":"task.status","task":"fix-login","state":"needs-decision","key":"second","text":"choose"}
{"v":1,"ts":1782900050,"event":"captain.answered","task":"fix-login","mode":"release"}
{"v":1,"ts":1782900050,"event":"captain.answered","task":"fix-login","mode":"done"}
{"v":1,"ts":1782900050,"event":"captain.answered","task":"fix-login","mode":"reconciled"}
EOF
  out=$(run_attention "$home") || fail "fm-attention failed: $out"
  printf '%s' "$out" | jq -e '
    [.session_activity[] | select(.event == "task.status") | .state] as $states
    | all(["failed", "blocked", "resolved", "done", "needs-decision"][]; . as $s | $states | index($s) != null)
    and ([.session_activity[] | select(.event == "task.status" and .state == "needs-decision") | .key] | sort) == ["first", "second", "shape"]
    and ([.session_activity[] | select(.task == "fix-login" and .event == "captain.answered") | .mode]) == ["reconciled", "done", "release"]
    and .session_activity_total == (.session_activity | length)
    and .session_activity_truncated == false' >/dev/null \
    || fail "distinct statuses, keys, answer modes and emission ordering must survive deduplication: $out"
  jq -nc 'range(0; 105) | {v:1, ts:(1782900100 + .), event:"task.dispatched", task:"fix-login"}' \
    >> "$home/state/fleet-ledger.jsonl"
  out=$(run_attention "$home") || fail "fm-attention failed: $out"
  printf '%s' "$out" | jq -e '.session_activity_total == 122
    and .session_activity_truncated == true and (.session_activity | length) == 100
    and .session_activity[0].at == (1782900204 | todate)
    and .session_activity[-1].at == (1782900105 | todate)' >/dev/null \
    || fail "the cap must disclose omitted distinct transitions: $out"
  pass "meaningful statuses and distinct decisions survive, true duplicates collapse, and the cap is disclosed"
}

test_current_pr_metadata_wins_over_history() {
  local home out
  home=$(activity_home activity-current-pr)
  rm -f "$home/config/fleet-ledger"
  : > "$home/state/.lock"
  TZ=UTC touch -t 202607010920.00 "$home/state/.lock"
  mkdir -p "$home/wt"
  fm_write_meta "$home/state/fix-login.meta" "window=firstmate:fm-fix-login" "worktree=$home/wt" \
    "project=$home/wt" "harness=claude" "kind=ship" "mode=no-mistakes" \
    "pr=https://example.test/acme/webapp/pull/8"
  out=$(run_attention "$home") || fail "fm-attention failed: $out"
  printf '%s' "$out" | jq -e '
    all(.session_activity[] | select(.task == "fix-login"); .pr == "https://example.test/acme/webapp/pull/8")
    and (.in_flight[] | select(.task == "fix-login") | .pr == "https://example.test/acme/webapp/pull/8")' >/dev/null \
    || fail "replacement metadata PR must beat ledger and event PRs in both feeds: $out"
  pass "current metadata PR wins for activity and in-flight items with recording disabled"
}

test_hold_answer_release_and_defer_are_recorded
test_reconcile_is_recorded
test_flag_off_writes_nothing
test_ledger_command_rejects_bad_captain_events
test_open_decisions_are_newest_first
test_ledger_events_move_last_touched
test_answered_call_is_not_open
test_read_is_side_effect_free_and_validates_arguments
test_date_only_hold_stamp
test_keyed_emission_order_with_large_delayed_ledger
test_opening_timestamp_acceptance
test_rehold_recency
test_continuations_preserve_opening_timestamps
test_legacy_rehold_preserves_effective_date
test_attention_skips_secondmate_collection
test_attention_uses_configured_adapter
test_session_activity_is_newest_first_and_distinct
test_in_flight_reports_the_worker_state
test_session_start_sources_and_fallback
test_activity_preserves_decisions_and_reports_cap
test_current_pr_metadata_wins_over_history
