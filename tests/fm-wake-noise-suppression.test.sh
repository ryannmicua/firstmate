#!/usr/bin/env bash
# tests/fm-wake-noise-suppression.test.sh - regressions for the deterministic
# wake-noise suppression owned by bin/fm-wake-suppress-lib.sh: repeat captain
# outcomes stored as routine, the drain's read-only --would-present probe, the
# empty-wake retirement and its shadow mode, the watcher's rearm-resurface
# gate, and the current crew state printed beside BRANCH OUTCOMES rows.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

OUTCOMES="$ROOT/bin/fm-branch-outcome.sh"
REPORT="$ROOT/bin/fm-branch-report.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-wake-noise-suppression-tests)

PR_URL=https://github.com/example/repo/pull/5
STALE_WAKE='stale: default:w4Q:p2 (paused 223003s, awaiting external - declared pause, rechecked on a long cadence not a wedge; confirm the wait still holds)'
STALE_WAKE_LATER='stale: default:w4Q:p2 (paused 254117s, awaiting external - declared pause, rechecked on a long cadence not a wedge; confirm the wait still holds)'

# new_home <name> [enforce]: a home with one paused task holding an open PR.
new_home() {
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/state" "$dir/config"
  : > "$dir/config/supervision-host"
  [ "${2:-}" != enforce ] || : > "$dir/config/wake-noise-suppression"
  printf 'kind=ship\npr=%s\npr_head=aaaa\n' "$PR_URL" > "$dir/state/ap1.meta"
  printf 'paused [at=1]: waiting on the merge decision for %s\n' "$PR_URL" > "$dir/state/ap1.status"
  : > "$dir/state/.watch-triage.log"
  printf '%s\n' "$dir"
}

in_home() {  # <dir> <command...>
  local dir=$1
  shift
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_CONFIG_OVERRIDE="$dir/config" "$@"
}

append() {  # <dir> <verdict> <wake> <summary>
  in_home "$1" "$OUTCOMES" append --task ap1 --verdict "$2" --wake "$3" --summary "$4" 2>>"$1/append.err"
}

stored_verdict() {  # <dir> <seq>
  in_home "$1" "$OUTCOMES" lookup --seqs "$2" | jq -r '.verdict'
}

stored_summary() {  # <dir> <seq>
  in_home "$1" "$OUTCOMES" lookup --seqs "$2" | jq -r '.summary'
}

# --- A: repeat captain outcomes ------------------------------------------------

test_repeat_captain_outcome_is_stored_routine_when_enforced() {
  local dir first second
  dir=$(new_home repeat-enforce enforce)
  first=$(append "$dir" captain "$STALE_WAKE" "AP-1 PR is still waiting on your merge decision: $PR_URL")
  second=$(append "$dir" captain "$STALE_WAKE_LATER" "AP-1 plan PR is open, clean, and still waiting on your merge call ($PR_URL). Worker idle.")
  assert_equals captain "$(stored_verdict "$dir" "$first")" "the first captain outcome must stay captain"
  assert_equals routine "$(stored_verdict "$dir" "$second")" "a reworded repeat with unchanged state must be stored routine"
  assert_contains "$(stored_summary "$dir" "$second")" "Repeat of captain outcome $first" "the stored repeat must name the outcome it repeats"
  assert_grep "suppressed repeat captain outcome $second for ap1" "$dir/state/.watch-triage.log" "the expected line is missing"
  assert_grep "repeats captain outcome $first" "$dir/append.err" "the expected line is missing"
  pass "a repeat captain outcome with unchanged status and PR state is stored as routine and logged"
}

test_repeat_captain_outcome_shadow_mode_only_logs() {
  local dir second
  dir=$(new_home repeat-shadow)
  append "$dir" captain "$STALE_WAKE" "AP-1 waiting on merge: $PR_URL" >/dev/null
  second=$(append "$dir" captain "$STALE_WAKE_LATER" "AP-1 still waiting on merge: $PR_URL")
  assert_equals captain "$(stored_verdict "$dir" "$second")" "shadow mode must not change the stored verdict"
  assert_grep "would suppress repeat captain outcome $second for ap1 (shadow mode)" "$dir/state/.watch-triage.log" "the expected line is missing"
  pass "without config/wake-noise-suppression a repeat captain outcome is only logged"
}

# Each case changes one piece of evidence between the two outcomes; none may be
# suppressed.
expect_not_suppressed() {  # <name> <mutation> <second wake> <second summary>
  local dir second
  dir=$(new_home "keep-$1" enforce)
  append "$dir" captain "$STALE_WAKE" "AP-1 waiting on merge: $PR_URL" >/dev/null
  eval "$2"
  second=$(append "$dir" captain "$3" "$4")
  assert_equals captain "$(stored_verdict "$dir" "$second")" "$1: the captain outcome must not be suppressed"
  assert_no_grep "repeat captain outcome $second" "$dir/state/.watch-triage.log" "an unexpected line is present"
}

# shellcheck disable=SC2016 # each mutation is evaluated inside expect_not_suppressed
test_changed_evidence_and_exempt_rows_are_never_suppressed() {
  expect_not_suppressed status-changed \
    'printf "done [at=2]: PR %s ready\n" "$PR_URL" >> "$dir/state/ap1.status"' \
    "$STALE_WAKE_LATER" "AP-1 waiting on merge: $PR_URL"
  expect_not_suppressed pr-head-changed \
    'sed -i.bak "s/^pr_head=.*/pr_head=bbbb/" "$dir/state/ap1.meta"' \
    "$STALE_WAKE_LATER" "AP-1 waiting on merge: $PR_URL"
  expect_not_suppressed pr-merge-notified \
    ': > "$dir/state/ap1.pr-poll-merge-notified"' \
    "$STALE_WAKE_LATER" "AP-1 waiting on merge: $PR_URL"
  expect_not_suppressed different-url ':' \
    "$STALE_WAKE_LATER" "AP-1 opened a second PR: https://github.com/example/repo/pull/6"
  expect_not_suppressed different-wake ':' \
    'signal: ap1.turn-ended' "AP-1 waiting on merge: $PR_URL"
  expect_not_suppressed escalation ':' \
    'stale: default:w4Q:p2 (idle 900s, possible wedge, escalation 2)' "AP-1 waiting on merge: $PR_URL"
  expect_not_suppressed heartbeat ':' \
    'heartbeat' "AP-1 waiting on merge: $PR_URL"
  expect_not_suppressed needs-decision-status \
    'printf "needs-decision [at=2]: merge or close %s\n" "$PR_URL" >> "$dir/state/ap1.status"; append "$dir" captain "$STALE_WAKE" "AP-1 waiting on merge: $PR_URL" >/dev/null' \
    "$STALE_WAKE_LATER" "AP-1 waiting on merge: $PR_URL"
  expect_not_suppressed missing-record \
    'rm -f "$dir/state/.ap1.captain-repeat"' \
    "$STALE_WAKE_LATER" "AP-1 waiting on merge: $PR_URL"
  pass "changed status or PR state, a different fingerprint, escalations, heartbeats, decisions, and missing evidence are never suppressed"
}

test_routine_rows_do_not_rebind_the_repeat_record() {
  local dir first second
  dir=$(new_home routine-between enforce)
  first=$(append "$dir" captain "$STALE_WAKE" "AP-1 waiting on merge: $PR_URL")
  append "$dir" routine "$STALE_WAKE" "AP-1 still paused, no change" >/dev/null
  second=$(append "$dir" captain "$STALE_WAKE_LATER" "AP-1 waiting on merge: $PR_URL")
  assert_equals routine "$(stored_verdict "$dir" "$second")" "a routine row between must not hide the repeat"
  assert_contains "$(stored_summary "$dir" "$second")" "captain outcome $first" "the repeat must point at the newest captain row"
  pass "routine rows between two captain outcomes leave the repeat comparison bound to the newest captain row"
}

test_branch_report_receipt_carries_the_stored_verdict() {
  local dir out
  dir=$(new_home receipt enforce)
  printf 'turn=t1\nunscoped=1\nposture=attended\nwake=%s\n' "$STALE_WAKE" > "$dir/state/.supervision-host-turn"
  in_home "$dir" env FM_SUPERVISION_ACTOR=branch FM_BRANCH_REPORT_TURN=t1 \
    "$REPORT" --task ap1 --verdict captain --summary "AP-1 waiting on merge: $PR_URL" >/dev/null 2>&1 \
    || fail "the first branch report was refused"
  out=$(in_home "$dir" env FM_SUPERVISION_ACTOR=branch FM_BRANCH_REPORT_TURN=t1 \
    "$REPORT" --task ap1 --verdict captain --summary "AP-1 still waiting on merge: $PR_URL" 2>/dev/null) \
    || fail "the repeat branch report was refused"
  assert_equals "captain routine" "$(awk -F '\t' '{ printf "%s%s", sep, $3; sep = " " }' "$dir/state/.supervision-host-receipts")" \
    "receipts must carry the stored verdicts so the host wakes main only for the first"
  assert_contains "$out" "[routine]" "the engine must be told the repeat was stored as routine"
  pass "the supervision host's receipt carries the stored routine verdict for a suppressed repeat"
}

# --- B: the drain probe ---------------------------------------------------------

probe() {  # <dir>
  local rc=0
  in_home "$1" "$DRAIN" --would-present >/dev/null 2>&1 || rc=$?
  printf '%s\n' "$rc"
}

test_would_present_probe_reads_every_presenting_section_without_writing() {
  local dir before after
  dir="$TMP_ROOT/probe"
  mkdir -p "$dir/state" "$dir/config"
  : > "$dir/config/supervision-host"
  before=$(find "$dir/state" -mindepth 1 | sort)
  assert_equals 1 "$(probe "$dir")" "an empty home has nothing to present"
  after=$(find "$dir/state" -mindepth 1 | sort)
  assert_equals "$before" "$after" "the probe must not create state"

  in_home "$dir" "$OUTCOMES" append --task t1 --verdict routine --summary "routine note" >/dev/null
  assert_equals 1 "$(probe "$dir")" "an unread routine outcome alone never needs main"
  in_home "$dir" "$OUTCOMES" append --task t1 --verdict captain --summary "captain call" >/dev/null
  assert_equals 0 "$(probe "$dir")" "an unprocessed captain outcome needs main"
  assert_equals 0 "$(probe "$dir")" "the probe must not mark the captain outcome read"

  dir="$TMP_ROOT/probe-decision"
  mkdir -p "$dir/state" "$dir/config"
  printf 'needs-decision [at=1] [key=k1]: pick one\n' > "$dir/state/d.status"
  assert_equals 0 "$(probe "$dir")" "an open decision needs main"

  dir="$TMP_ROOT/probe-unread"
  mkdir -p "$dir/state" "$dir/config"
  printf 'note [at=1]: the answer arrived\n' > "$dir/state/n.status"
  assert_equals 0 "$(probe "$dir")" "an unread status note needs main"
  assert_equals 0 "$(probe "$dir")" "the probe must not consume the unread note"

  dir="$TMP_ROOT/probe-queue"
  mkdir -p "$dir/state" "$dir/config"
  append_wake "$dir/state" check some-check "check: something happened"
  assert_equals 0 "$(probe "$dir")" "a queued row needs main"
  pass "--would-present answers for queued rows, unread status, decisions, and captain outcomes, ignores routine rows, and writes nothing"
}

# --- B: empty-wake retirement ---------------------------------------------------

suppress() {  # <dir> <wake text> -> rc of candidate && commit
  # shellcheck disable=SC2016 # the inner script expands its own arguments
  in_home "$1" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    . "$1/bin/fm-wake-suppress-lib.sh"
    fm_wake_suppress_candidate "$2" && fm_wake_suppress_commit test-site "$2"
  ' _ "$ROOT" "$2"
}

publish_downtime() {  # <dir>
  # shellcheck disable=SC2016 # the inner script expands its own arguments
  in_home "$1" bash -c '. "$1/bin/fm-wake-lib.sh"; fm_recovery_marker_publish "$STATE/.watcher-down" downtime' _ "$ROOT"
}

test_empty_wake_is_retired_only_when_enforced() {
  local dir
  dir="$TMP_ROOT/empty-enforce"
  mkdir -p "$dir/state" "$dir/config"
  : > "$dir/config/wake-noise-suppression"
  publish_downtime "$dir"
  suppress "$dir" 'check: rearm-resurface' || fail "an empty recovery wake was not suppressed in enforce mode"
  assert_contains "$(cat "$dir/state/.watcher-down")" "acked:" "the suppressed wake's recovery episode must be retired"
  assert_grep 'suppressed empty wake (test-site): check: rearm-resurface' "$dir/state/.watch-triage.log" "the expected line is missing"

  dir="$TMP_ROOT/empty-shadow"
  mkdir -p "$dir/state" "$dir/config"
  publish_downtime "$dir"
  if suppress "$dir" 'check: rearm-resurface'; then fail "shadow mode suppressed a wake"; fi
  assert_contains "$(cat "$dir/state/.watcher-down")" "pending:downtime" "shadow mode must leave the recovery episode open"
  assert_grep 'would suppress empty wake (test-site, shadow mode)' "$dir/state/.watch-triage.log" "the expected line is missing"
  pass "an empty wake is retired and logged when enforced, and only logged in shadow mode"
}

test_must_not_suppress_wakes_reach_main() {
  local dir wake
  for wake in 'heartbeat' 'heartbeat: 3 tasks' \
    'stale: default:w1:p1 (idle 900s, possible wedge, escalation 1)' \
    'stale: default:w1:p1 (idle 900s, possible wedge, escalation 3, demand-deep-inspection: same pane)' \
    'signal: t1.status needs-decision' \
    'supervision-host: cycle boundary'; do
    dir="$TMP_ROOT/exempt-$(printf '%s' "$wake" | cksum | cut -d' ' -f1)"
    mkdir -p "$dir/state" "$dir/config"
    : > "$dir/config/wake-noise-suppression"
    publish_downtime "$dir"
    if suppress "$dir" "$wake"; then fail "an exempt wake was suppressed: $wake"; fi
    assert_contains "$(cat "$dir/state/.watcher-down")" "pending:downtime" "an exempt wake must leave its episode open: $wake"
  done

  dir="$TMP_ROOT/exempt-away"
  mkdir -p "$dir/state" "$dir/config"
  : > "$dir/config/wake-noise-suppression"
  : > "$dir/state/.afk-contract"
  publish_downtime "$dir"
  if suppress "$dir" 'check: rearm-resurface'; then fail "a wake was suppressed under an away record"; fi

  dir="$TMP_ROOT/exempt-work"
  mkdir -p "$dir/state" "$dir/config"
  : > "$dir/config/wake-noise-suppression"
  publish_downtime "$dir"
  printf 'blocked [at=1] [key=b1]: credential missing\n' > "$dir/state/b.status"
  if suppress "$dir" 'check: rearm-resurface'; then fail "a wake was suppressed while a blocker is open"; fi
  pass "heartbeats, escalations, decisions, host lines, away records, and open work always reach main"
}

# --- B: the watcher's rearm-resurface gate --------------------------------------

# Run the watcher for up to <seconds>, or until <until-file> contains
# <until-text>, then copy the recovery marker the live watcher left to
# marker.seen before stopping it (a stopped watcher republishes downtime).
run_watcher_briefly() {  # <dir> <seconds> [<until-file> <until-text>]
  local dir=$1 secs=$2 until_file=${3:-} until_text=${4:-} child i=0
  : > "$dir/watch.out"
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_CONFIG_OVERRIDE="$dir/config" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH" > "$dir/watch.out" 2>&1 &
  child=$!
  while [ "$i" -lt "$((secs * 10))" ] && kill -0 "$child" 2>/dev/null; do
    if [ -n "$until_file" ] && grep -F -- "$until_text" "$until_file" >/dev/null 2>&1; then
      sleep 1
      break
    fi
    sleep 0.1
    i=$((i + 1))
  done
  cat "$dir/state/.watcher-down" > "$dir/marker.seen" 2>/dev/null || true
  kill -0 "$child" 2>/dev/null && printf 'alive\n' > "$dir/watcher.alive"
  kill -TERM "$child" 2>/dev/null || true
  wait "$child" 2>/dev/null || true
}

watcher_home() {  # <name> [enforce]
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/state" "$dir/config" "$dir/fakebin"
  fm_test_track_watcher_state "$dir/state"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/fakebin/tmux"
  chmod +x "$dir/fakebin/tmux"
  [ "${2:-}" != enforce ] || : > "$dir/config/wake-noise-suppression"
  : > "$dir/state/crew.meta"
  printf 'pending:downtime:gap.1.aaa\n' > "$dir/state/.watcher-down"
  chmod 600 "$dir/state/.watcher-down"
  printf '%s\n' "$dir"
}

test_watcher_keeps_watching_instead_of_an_empty_rearm_resurface() {
  local dir
  dir=$(watcher_home watcher-enforce enforce)
  run_watcher_briefly "$dir" 30 "$dir/state/.watch-triage.log" 'suppressed empty wake (watcher-resurface)'
  assert_grep 'suppressed empty wake (watcher-resurface)' "$dir/state/.watch-triage.log" "the enforced watcher did not log its suppression"
  assert_no_grep 'check: rearm-resurface' "$dir/watch.out" "the enforced watcher still announced an empty recovery"
  assert_contains "$(cat "$dir/marker.seen")" "acked:" "the empty recovery episode must be retired"
  assert_present "$dir/watcher.alive" "the watcher must keep watching after suppressing the recovery"

  dir=$(watcher_home watcher-shadow)
  run_watcher_briefly "$dir" 30
  assert_grep 'check: rearm-resurface' "$dir/watch.out" "shadow mode must still announce the recovery"
  assert_grep 'would suppress empty wake (watcher-resurface, shadow mode)' "$dir/state/.watch-triage.log" "the expected line is missing"

  dir=$(watcher_home watcher-open-decision enforce)
  printf 'needs-decision [at=1] [key=k1]: choose\n' > "$dir/state/crew.status"
  run_watcher_briefly "$dir" 30
  assert_grep 'check: rearm-resurface' "$dir/watch.out" "a recovery with an open decision must still be announced"
  pass "the watcher retires an empty recovery and keeps watching when enforced, and still announces in shadow mode or with work open"
}

# --- D: current state beside BRANCH OUTCOMES ------------------------------------

test_branch_outcomes_show_the_current_crew_state() {
  local dir out
  dir="$TMP_ROOT/outcomes-current"
  mkdir -p "$dir/state" "$dir/config"
  : > "$dir/config/supervision-host"
  in_home "$dir" "$OUTCOMES" append --task gone-task --verdict captain --summary "gone-task needs your call" >/dev/null
  out=$(in_home "$dir" "$DRAIN" 2>/dev/null)
  assert_contains "$out" "gone-task: gone-task needs your call" "the captain outcome must be presented"
  assert_contains "$out" "  current: state: unknown · source: none · no metadata for gone-task" \
    "the task's current crew state must follow its outcome line"
  pass "each BRANCH OUTCOMES captain line is followed by the task's current crew state"
}

test_repeat_captain_outcome_is_stored_routine_when_enforced
test_repeat_captain_outcome_shadow_mode_only_logs
test_changed_evidence_and_exempt_rows_are_never_suppressed
test_routine_rows_do_not_rebind_the_repeat_record
test_branch_report_receipt_carries_the_stored_verdict
test_would_present_probe_reads_every_presenting_section_without_writing
test_empty_wake_is_retired_only_when_enforced
test_must_not_suppress_wakes_reach_main
test_watcher_keeps_watching_instead_of_an_empty_rearm_resurface
test_branch_outcomes_show_the_current_crew_state
