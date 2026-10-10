#!/usr/bin/env bash
# fm-wake-suppress-lib.sh - deterministic wake-noise suppression: keep no-op
# supervision wakes out of the main session without a model in the loop.
#
# CONTRACT (this header is the one owner of the policy; callers own only where
# they apply it). Two suppressions share one switch and one log:
#
#   - Repeat captain outcomes (bin/fm-branch-outcome.sh append): a captain
#     outcome for a task whose newest captain outcome carries the same
#     fingerprint, and whose status log and recorded PR state have not changed
#     since that outcome, is stored as a routine outcome instead, so neither
#     the supervision host nor the Pi branch wakes main for it. The
#     fingerprint is the task, wake text, and summary substance, with only
#     the changing idle or paused age normalized. The recorded PR
#     state is the task meta's pr= and pr_head= lines plus its PR poll
#     registration and merge-notified receipt. fm_wake_suppress_repeat_record
#     keeps that evidence in state/.<task>.captain-repeat, bound to the store
#     sequence of the task's newest captain row; anything missing, malformed,
#     or bound to another row means no suppression.
#   - Empty wakes (the watcher's check: rearm-resurface, the supervision host's
#     attended main-only pass-through, and the Claude Stop hook's rewake on a
#     home without the host): before a close goes to main, when main's drain
#     would present nothing (bin/fm-wake-drain.sh --would-present: no queued
#     row, no UNREAD STATUS, no STATUS OUTCOME BACKSTOP, no OPEN DECISIONS, no
#     RECORD DIVERGENCE, and no captain BRANCH OUTCOMES row), the open recovery
#     episode is retired with the same generation-bound acknowledgement main's
#     drain prints for an empty queue, the drain is asked again, and the caller
#     keeps supervising instead of waking main. Routine outcome rows do not
#     count: they never wait on main's acknowledgement and the next real drain
#     still lists them. The one-shot session-start digest and a session that
#     does not hold the fleet lock never reach these call sites.
#
# Never suppressed: a wake or outcome summary naming a heartbeat, an escalation (including any
# escalation count or demand-deep-inspection), a needs-decision or blocked
# event, a supervision-host line, or a failure; a captain outcome whose task's
# newest status event is needs-decision or blocked; anything while an away or
# quiet record exists; and every case where the evidence cannot be read.
# Uncertainty always wakes main.
#
# Switch: config/wake-noise-suppression, a local, gitignored presence flag.
# Absent (the default), both run in shadow mode: they decide exactly as above
# but leave verdicts and wake delivery unchanged while recording comparison
# evidence and logging what they would have suppressed. Present, they
# suppress. Every decision to suppress, in either mode, appends one line to
# state/.watch-triage.log ("suppressed ..." or "would suppress ...").
#
# Requires fm-wake-lib.sh to be sourced first (STATE, FM_HOME, locks, the
# recovery marker).

FM_WAKE_SUPPRESS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_WAKE_SUPPRESS_REPEAT_VERSION=fm-captain-repeat-v2

fm_wake_suppress_config() {
  printf '%s\n' "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
}

# Print enforce or shadow for this home.
fm_wake_suppress_mode() {
  if [ -e "$(fm_wake_suppress_config)/wake-noise-suppression" ]; then
    printf 'enforce\n'
  else
    printf 'shadow\n'
  fi
}

# Append one bounded line to the watcher's triage log, in its format.
fm_wake_suppress_log() {  # <text>
  local log="$STATE/.watch-triage.log" max=${FM_WATCH_TRIAGE_LOG_MAX_BYTES:-262144} sz
  printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$(printf '%s' "$1" | tr '\t\r\n' '   ' | cut -c1-600)" \
    >> "$log" 2>/dev/null || return 0
  sz=$(wc -c < "$log" 2>/dev/null | tr -d '[:space:]')
  case "$sz" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$sz" -ge "$max" ]; then
    tail -n 2000 "$log" > "$log.tmp" 2>/dev/null && mv -f "$log.tmp" "$log" 2>/dev/null
    rm -f "$log.tmp" 2>/dev/null || true
  fi
}

# True when <text> must never be suppressed (header, "Never suppressed").
fm_wake_suppress_exempt() {  # <wake text, one or more lines>
  local text=$1 line lower
  [ -n "$text" ] || return 0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      heartbeat*|supervision-host*|watcher:*) return 0 ;;
    esac
    lower=$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]')
    case "$lower" in
      *escalat*|*demand-deep-inspection*|*decision*|*blocked*|*failed*|*failure*) return 0 ;;
    esac
  done <<EOF
$text
EOF
  return 1
}

fm_wake_suppress_away() {
  [ -e "$STATE/.afk" ] || [ -e "$STATE/.afk-contract" ] || [ -L "$STATE/.afk-contract" ]
}

# --- empty wakes -------------------------------------------------------------

# True only when main's drain provably would present nothing; any error reads
# as something to present.
fm_wake_main_would_present_nothing() {
  local rc=0
  FM_SUPERVISION_ACTOR=main "$FM_WAKE_SUPPRESS_LIB_DIR/fm-wake-drain.sh" --would-present >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 1 ]
}

# Retire the open recovery episode exactly as main's empty-queue
# acknowledgement would. True when no episode is left open.
fm_wake_retire_empty_episode() {
  local marker="$STATE/.watcher-down" generation
  fm_recovery_marker_snapshot "$marker" || return 1
  case "$FM_RECOVERY_MARKER_TOKEN" in
    '')
      { [ -e "$marker" ] || [ -L "$marker" ]; } && return 1
      return 0
      ;;
    acked:*) return 0 ;;
    pending:*|announced:*) generation=${FM_RECOVERY_MARKER_TOKEN##*:} ;;
    *) return 1 ;;
  esac
  # The acknowledgement reads the queue file, which a presenting drain creates
  # under the queue lock when it is absent; do the same.
  if [ ! -e "$FM_WAKE_QUEUE" ] && [ ! -L "$FM_WAKE_QUEUE" ]; then
    fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || return 1
    if [ ! -e "$FM_WAKE_QUEUE" ] && [ ! -L "$FM_WAKE_QUEUE" ]; then
      : > "$FM_WAKE_QUEUE" || { fm_lock_release "$FM_WAKE_QUEUE_LOCK"; return 1; }
    fi
    fm_lock_release "$FM_WAKE_QUEUE_LOCK"
  fi
  FM_SUPERVISION_ACTOR=main "$FM_WAKE_SUPPRESS_LIB_DIR/fm-wake-drain.sh" \
    --ack-through 0 --recovery-generation "$generation" >/dev/null 2>&1 || return 1
  fm_recovery_marker_snapshot "$marker" || return 1
  case "$FM_RECOVERY_MARKER_TOKEN" in acked:*) return 0 ;; esac
  return 1
}

# The cheap half of the empty-wake decision, run before a caller does any
# work it would only need for a suppression: true when <wake text> may be
# suppressed and main's drain would present nothing.
fm_wake_suppress_candidate() {  # <wake text>
  fm_wake_suppress_exempt "$1" && return 1
  fm_wake_suppress_away && return 1
  fm_wake_main_would_present_nothing
}

# The deciding half, after fm_wake_suppress_candidate: in shadow mode log and
# return 1; in enforce mode retire the episode, re-check the drain, and return
# 0 only when the wake was suppressed.
fm_wake_suppress_commit() {  # <where> <wake text>
  local where=$1 first
  first=$(printf '%s\n' "$2" | head -n 1)
  if [ "$(fm_wake_suppress_mode)" != enforce ]; then
    fm_wake_suppress_log "would suppress empty wake ($where, shadow mode): $first"
    return 1
  fi
  if ! fm_wake_retire_empty_episode; then
    fm_wake_suppress_log "kept empty wake ($where): its recovery episode could not be retired: $first"
    return 1
  fi
  if ! fm_wake_main_would_present_nothing; then
    fm_wake_suppress_log "kept empty wake ($where): work arrived while it was being retired: $first"
    return 1
  fi
  fm_wake_suppress_log "suppressed empty wake ($where): $first"
  return 0
}

# --- repeat captain outcomes ---------------------------------------------------

_fm_wake_suppress_cksum() {
  cksum | awk '{ print $1 ":" $2 }'
}

# The outcome fingerprint (header).
fm_wake_suppress_outcome_fingerprint() {  # <task> <wake> <summary>
  {
    printf '%s\n' "$1"
    printf '%s' "$2" | tr '\t\r\n' '   ' | sed -E 's/((idle|paused) )[0-9]+s/\1#s/g; s/^[[:space:]]+//; s/[[:space:]]+$//'
    printf '\n%s\n' "$3"
  } | _fm_wake_suppress_cksum
}

# The recorded PR state (header).
fm_wake_suppress_pr_state() {  # <task>
  local task=$1 f data='' contents
  f="$STATE/$task.meta"
  if [ -e "$f" ] || [ -L "$f" ]; then
    [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || return 1
    contents=$(cat "$f" 2>/dev/null && printf '\001') || return 1
    contents=${contents%$'\001'}
    contents=$(printf '%s\n' "$contents" | awk '/^(pr|pr_head)=/') || return 1
    data="$contents"
  fi
  for f in "$STATE/$task.pr-poll" "$STATE/$task.pr-poll-merge-notified"; do
    data="$data
${f##*/}"
    if [ -e "$f" ] || [ -L "$f" ]; then
      [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || return 1
      contents=$(cat "$f" 2>/dev/null && printf '\001') || return 1
      contents=${contents%$'\001'}
      data="$data
present
$contents"
    fi
  done
  printf '%s\n' "$data" | _fm_wake_suppress_cksum
}

fm_wake_suppress_repeat_path() {  # <task>
  case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  printf '%s/.%s.captain-repeat' "$STATE" "$1"
}

# True when the task's newest status event is a decision or blocker.
_fm_wake_suppress_status_holds_decision() {  # <task>
  local f="$STATE/$1.status" last verb
  [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || return 0
  last=$(awk 'NF { line = $0 } END { print line }' "$f" 2>/dev/null) || return 0
  verb=$(printf '%s' "$last" | sed -E 's/^[[:space:]]*([A-Za-z-]+).*/\1/')
  case "$verb" in needs-decision|blocked) return 0 ;; esac
  return 1
}

# Decide whether a captain outcome about to be appended repeats the task's
# newest captain outcome. Run under the outcome store lock after the status
# position was captured. Sets FM_WAKE_REPEAT_OF to that outcome's sequence
# when it does, and empty otherwise. <newest-captain-seq> is the sequence of
# the task's newest captain row in the validated store (empty when none).
# shellcheck disable=SC2034 # FM_WAKE_REPEAT_OF is an output global read by the outcome-store caller.
fm_wake_suppress_repeat_of() {  # <task> <wake> <summary> <status-endpoint> <status-ident> <newest-captain-seq>
  local task=$1 wake=$2 summary=$3 endpoint=$4 ident=$5 newest=$6 path data
  local version seq fp rec_endpoint rec_ident pr extra current_pr
  FM_WAKE_REPEAT_OF=
  [ -n "$newest" ] || return 0
  [ "$ident" != - ] || return 0
  fm_wake_suppress_away && return 0
  fm_wake_suppress_exempt "$wake" && return 0
  fm_wake_suppress_exempt "$summary" && return 0
  _fm_wake_suppress_status_holds_decision "$task" && return 0
  path=$(fm_wake_suppress_repeat_path "$task") || return 0
  [ -f "$path" ] && [ ! -L "$path" ] && [ -r "$path" ] || return 0
  data=$(head -c 1024 "$path" 2>/dev/null) || return 0
  case "$data" in *$'\n'*) return 0 ;; esac
  IFS=$(printf '\t') read -r version seq fp rec_endpoint rec_ident pr extra <<EOF
$data
EOF
  [ "$version" = "$FM_WAKE_SUPPRESS_REPEAT_VERSION" ] && [ -z "$extra" ] || return 0
  [ "$seq" = "$newest" ] || return 0
  [ "$fp" = "$(fm_wake_suppress_outcome_fingerprint "$task" "$wake" "$summary")" ] || return 0
  [ "$rec_endpoint" = "$endpoint" ] && [ "$rec_ident" = "$ident" ] || return 0
  current_pr=$(fm_wake_suppress_pr_state "$task") || return 0
  [ "$pr" = "$current_pr" ] || return 0
  FM_WAKE_REPEAT_OF=$seq
}

# Record the evidence for a captain outcome that was just stored as captain.
fm_wake_suppress_repeat_record() {  # <task> <seq> <wake> <summary> <status-endpoint> <status-ident>
  local path tmp pr
  path=$(fm_wake_suppress_repeat_path "$1") || return 1
  pr=$(fm_wake_suppress_pr_state "$1") || return 1
  tmp=$(mktemp "$STATE/.captain-repeat.XXXXXX") || return 1
  if ! printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$FM_WAKE_SUPPRESS_REPEAT_VERSION" "$2" \
      "$(fm_wake_suppress_outcome_fingerprint "$1" "$3" "$4")" "$5" "$6" \
      "$pr" > "$tmp" \
    || ! mv -f -- "$tmp" "$path"; then
    rm -f -- "$tmp"
    return 1
  fi
}
