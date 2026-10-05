#!/usr/bin/env bash
# fm-task-inbox-lib.sh - the per-task steering inbox: durable records plus a
# constant doorbell.
#
# ONE owner of the steering-inbox contract: the record format, sequence
# allocation, the idempotent re-enqueue dedup, the handled/ acknowledgement,
# the self-describing doorbell line, and the watcher's re-ring ladder policy.
# bin/fm-send.sh writes and rings locally, the host-local remote steer leg
# (bin/fm-remote-secondmate-control.sh cmd_send) writes idempotently and rings
# on the remote host, bin/fm-watch.sh polls and re-rings, and the brief
# scaffold (bin/fm-brief.sh) tells the worker how to read and acknowledge;
# none of them restates the format.
#
# Design (captain-adopted, data/fm-send-reliability-reframe-s1/report.md): the
# payload moves to the filesystem, which is reliable; the terminal carries only
# a short constant doorbell line. While the endpoint remains available, that
# line does not need to be reliable because ringing it again is free. A
# duplicated doorbell is a no-op by construction (the worker finds the inbox
# empty or already handled), and a swallowed doorbell is detected by the
# absence of the worker's acknowledgement and re-rung on a bounded schedule.
# A positively dead or missing endpoint bypasses that schedule without being
# typed into, and its unhandled record surfaces through the ordinary stale wake
# into stuck-crewmate-recovery.
#
# Layout under <state-dir>:
#   <task>.inbox/NNN.msg       one durable steer, numeric sequence, atomic rename
#   <task>.inbox/handled/      the worker's `mv` here IS the acknowledgement
#   <task>.inbox/.seq.lock     serializes sequence allocation across writers
#                              (the session and the away daemon)
#   <task>.inbox/.ring-state   watcher re-ring ladder: "<msg>\t<count>\t<epoch>"
#   <task>.inbox/.escalated    oldest-message name already surfaced as stale,
#                              so later polls suppress another escalation
#   <task>.inbox/.busy-enter   oldest-message name whose pending doorbell
#                              already got its one Enter on a busy pane
#
# Record format (fm_task_inbox_write / fm_task_inbox_body):
#   schema=fm-task-inbox.v1
#   at=<utc timestamp>
#   delivery=fire-and-forget   present only when the re-ring ladder must ignore it
#   --
#   <exact message text; newlines are legal; a marked secondmate request keeps
#    its from-firstmate marker and corr token verbatim in this body>
#
# Sequence numbers are never reused within a task: allocation scans both the
# inbox root and handled/, so a message is processed at most once per worker
# lifetime even if every doorbell is duplicated. Concurrent writers serialize
# on .seq.lock; the worst racing outcome is ordering, never loss.
#
# Re-ring ladder (fm_task_inbox_due_action): an unhandled message older than
# FM_TASK_INBOX_GRACE_SECS is due one delivery attempt per grace period; an
# attempt may ring, resubmit this inbox's exactly recognized doorbell left in the
# composer by a swallowed Enter (Enter only, never retyped), or be skipped when
# the composer is exactly proven pending with other text. Ambiguous composers
# still use type-and-submit by design, so an unreadable harness is not starved.
# After FM_TASK_INBOX_RING_MAX attempts without an acknowledgement it escalates.
# The watcher owns its busy and recovery-grade endpoint checks: it does not type
# into a pane it has classified busy or spend a ladder attempt there, though that
# pane's recognized own doorbell gets one Enter per message
# (fm_task_inbox_claim_busy_enter). A positively dead or missing endpoint skips
# delivery and the ladder and escalates directly. This library owns only the
# schedule and the escalation and busy-Enter markers.
# If attempt bookkeeping cannot be persisted while the record remains unhandled,
# the caller surfaces that failure instead of retrying silently; a concurrently
# removed inbox is a quiet no-op. Escalation deliberately queues the wake before
# writing the deduplication marker: normal polls surface a message once, while a
# crash or marker failure may produce a rare duplicate rather than silently lose
# a wake.
#
# Inbox paths containing bytes outside printable ASCII are unsupported. The
# doorbell refuses them rather than sending terminal control bytes to a pane.
#
# fm_task_inbox_ring requires bin/fm-backend.sh's dispatch (sourced below); the
# other helpers are dependency-light. Sourced by bin/fm-send.sh, bin/fm-watch.sh,
# and tests. No side effects on source beyond its sourced libraries.
#
# Tunables (env):
#   FM_TASK_INBOX_GRACE_SECS   default 90; delivery-attempt grace and spacing
#   FM_TASK_INBOX_RING_MAX     default 3; delivery attempts before escalation

_FM_TASK_INBOX_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Each dependency is a canonical lint root in its own right. Keep them as
# analysis boundaries here so ShellCheck's external-source traversal does not
# recursively duplicate the full backend graph for every inbox consumer.
# shellcheck source=/dev/null
. "$_FM_TASK_INBOX_LIB_DIR/fm-wake-lib.sh"
# shellcheck source=/dev/null
. "$_FM_TASK_INBOX_LIB_DIR/fm-backend.sh"
# shellcheck source=bin/fm-composer-lib.sh
. "$_FM_TASK_INBOX_LIB_DIR/fm-composer-lib.sh"

FM_TASK_INBOX_SCHEMA='fm-task-inbox.v1'
FM_TASK_INBOX_GRACE_DEFAULT=90
FM_TASK_INBOX_RING_MAX_DEFAULT=3
FM_TASK_INBOX_LOCK_WAIT_DEFAULT=5

fm_task_inbox_grace_secs() {
  local g=${FM_TASK_INBOX_GRACE_SECS:-$FM_TASK_INBOX_GRACE_DEFAULT}
  case "$g" in ''|*[!0-9]*) g=$FM_TASK_INBOX_GRACE_DEFAULT ;; esac
  printf '%s' "$g"
}

fm_task_inbox_ring_max() {
  local m=${FM_TASK_INBOX_RING_MAX:-$FM_TASK_INBOX_RING_MAX_DEFAULT}
  case "$m" in ''|*[!0-9]*) m=$FM_TASK_INBOX_RING_MAX_DEFAULT ;; esac
  printf '%s' "$m"
}

fm_task_inbox_dir() {  # <state-dir> <task-id>
  printf '%s/%s.inbox' "$1" "$2"
}

fm_task_inbox_handled_dir() {  # <state-dir> <task-id>
  printf '%s/%s.inbox/handled' "$1" "$2"
}

# Numeric sequence of one record basename, or fail for a non-record name.
fm_task_inbox_seq_of() {  # <basename>
  local n=${1%.msg}
  [ "$n" != "$1" ] || return 1
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$((10#$n))"
}

# Next unused sequence, scanning the inbox root AND handled/ so an
# acknowledged sequence is never reissued. Caller must hold .seq.lock.
fm_task_inbox_next_seq() {  # <inbox-dir>
  local dir=$1 max=0 d f n
  for d in "$dir" "$dir/handled"; do
    for f in "$d"/*.msg; do
      [ -e "$f" ] || continue
      n=$(fm_task_inbox_seq_of "${f##*/}") || continue
      [ "$n" -le "$max" ] || max=$n
    done
  done
  printf '%03d' "$((max + 1))"
}

fm_task_inbox_lock_acquire() {  # <lock-path>
  local lock=$1 wait=${FM_TASK_INBOX_LOCK_WAIT_SECS:-$FM_TASK_INBOX_LOCK_WAIT_DEFAULT}
  local deadline probe
  case "$wait" in ''|*[!0-9]*) wait=$FM_TASK_INBOX_LOCK_WAIT_DEFAULT ;; esac
  probe=$(mktemp "${lock%/*}/.lock-probe.XXXXXX") || return 1
  rm -f "$probe" || return 1
  if [ ! -e "$lock" ] && [ ! -L "$lock" ]; then
    fm_lock_try_create "$lock" && return 0
  fi
  deadline=$(( $(date +%s) + wait ))
  while ! fm_lock_try_acquire "$lock"; do
    [ "$(date +%s)" -lt "$deadline" ] || return 1
    sleep 0.1
  done
}

# Write one record into the next sequence slot: temp-write, then atomic
# rename. Prints the record path. Caller must hold .seq.lock.
_fm_task_inbox_write_record_locked() {  # <inbox-dir> <text> [delivery-mode]
  local dir=$1 text=$2 delivery_mode=${3:-} seq tmp rec status=0
  seq=$(fm_task_inbox_next_seq "$dir")
  rec="$dir/$seq.msg"
  tmp=$(mktemp "$dir/.staging.XXXXXX") || return 1
  {
    printf 'schema=%s\n' "$FM_TASK_INBOX_SCHEMA"
    printf 'at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    [ "$delivery_mode" != fire-and-forget ] || printf 'delivery=fire-and-forget\n'
    printf -- '--\n'
    printf '%s' "$text"
  } > "$tmp" && mv "$tmp" "$rec" || status=1
  [ "$status" -eq 0 ] || { rm -f "$tmp"; return 1; }
  printf '%s' "$rec"
}

# Durably enqueue one steer: temp-write, then atomic rename into the next
# sequence slot. Prints the record path. Fails without a partial record.
fm_task_inbox_write() {  # <state-dir> <task-id> <text> [delivery-mode]
  local state=$1 task=$2 text=$3 delivery_mode=${4:-} dir lock rec status=0
  dir=$(fm_task_inbox_dir "$state" "$task")
  mkdir -p "$dir/handled" || return 1
  lock="$dir/.seq.lock"
  fm_task_inbox_lock_acquire "$lock" || return 1
  rec=$(_fm_task_inbox_write_record_locked "$dir" "$text" "$delivery_mode") || status=1
  fm_lock_release "$lock"
  [ "$status" -eq 0 ] || return 1
  printf '%s' "$rec"
}

# Durably enqueue one steer at most once: when a record with the exact same
# body already exists - unhandled or already acknowledged in handled/ - no new
# record is written and the existing record's path is printed instead.
# This is the enqueue primitive for a transport that can fail with completion
# unknown (the remote steer leg over ssh): the caller's safe recovery is to run
# the same enqueue again, and this dedup is what makes the re-run land on the
# same record instead of a duplicate the worker would act on twice. Two
# distinct logical requests never collapse in practice because a marked
# secondmate request embeds a per-request correlation token in its body. The
# local plane keeps plain fm_task_inbox_write: its outcome is synchronous, so
# a repeated identical local steer is a deliberate new instruction.
fm_task_inbox_write_idempotent() {  # <state-dir> <task-id> <text> [delivery-mode]
  local state=$1 task=$2 text=$3 delivery_mode=${4:-} dir lock want have f rec='' status=0
  dir=$(fm_task_inbox_dir "$state" "$task")
  mkdir -p "$dir/handled" || return 1
  lock="$dir/.seq.lock"
  fm_task_inbox_lock_acquire "$lock" || return 1
  if want=$(mktemp "$dir/.dedup.XXXXXX") && have=$(mktemp "$dir/.dedup.XXXXXX"); then
    if printf '%s' "$text" > "$want"; then
      for f in "$dir"/*.msg "$dir/handled"/*.msg; do
        if [ ! -e "$f" ]; then
          case "$f" in
            "$dir"/*.msg)
              f="$dir/handled/${f##*/}"
              [ -e "$f" ] || continue
              ;;
            *) continue ;;
          esac
        fi
        if [ "$delivery_mode" = fire-and-forget ]; then
          fm_task_inbox_is_fire_and_forget "$f" || continue
        elif fm_task_inbox_is_fire_and_forget "$f"; then
          continue
        fi
        if ! fm_task_inbox_body "$f" > "$have" 2>/dev/null; then
          case "$f" in
            "$dir"/*.msg)
              f="$dir/handled/${f##*/}"
              fm_task_inbox_body "$f" > "$have" 2>/dev/null || continue
              ;;
            *) continue ;;
          esac
        fi
        cmp -s "$want" "$have" || continue
        [ ! -e "$dir/handled/${f##*/}" ] || f="$dir/handled/${f##*/}"
        rec=$f
        break
      done
    else
      status=1
    fi
    rm -f "$want" "$have"
  else
    rm -f "${want:-}" 2>/dev/null || true
    status=1
  fi
  if [ "$status" -eq 0 ] && [ -z "$rec" ]; then
    rec=$(_fm_task_inbox_write_record_locked "$dir" "$text" "$delivery_mode") || status=1
  fi
  fm_lock_release "$lock"
  [ "$status" -eq 0 ] || return 1
  printf '%s' "$rec"
}

# The exact enqueued text back out of a record.
fm_task_inbox_body() {  # <record-path>
  local line
  [ -f "$1" ] || return 1
  while IFS= read -r line; do
    if [ "$line" = -- ]; then
      cat
      return 0
    fi
  done < "$1"
  return 1
}

# The constant self-describing doorbell line for the inbox containing a record.
# Self-describing on purpose: a worker whose brief predates the inbox contract
# still receives the complete instruction in the line itself. The leading `: `
# is the POSIX shell no-op, so the same line typed into a pane whose agent has
# exited (a bare shell) runs nothing; see the dead-pane note in the header.
# A non-printable path fails without output so terminal controls never reach
# the pane's line discipline.
fm_task_inbox_doorbell_line() {  # <record-path>
  local dir=${1%/*} abs quoted LC_ALL=C
  abs=$(cd "$dir" 2>/dev/null && pwd) || abs=$dir
  abs=${abs%/handled}
  case "$abs" in
    *[![:print:]]*) return 1 ;;
  esac
  quoted=$(printf '%s' "$abs" | sed "s/'/'\\\\''/g")
  printf ": Firstmate instruction waiting: list '%s'/*.msg and, in numeric order, read and act on each, then mv each handled file to '%s'/handled/." \
    "$quoted" "$quoted"
}

# Whether a captured <screen>'s composer holds nothing but copies of this
# record's own doorbell line: the residue of a ring whose Enter the harness
# swallowed. Live codex-cli 0.160.0 turns an Enter that arrives in the same
# input read as the typed line into a newline, leaving the doorbell in the
# composer (verified on tmux and Herdr, idle and mid-turn; docs/verification/
# runtime-backends.md "Swallowed-Enter recovery").
# The doorbell line is constant per inbox, so a copy left by an earlier ring
# is recognized too. This identifies a recognized own doorbell for Enter-only
# recovery. Only an exact `pending` composer verdict protects other text;
# `pending-unproven` and `unknown` still use type-and-submit by design.
fm_task_inbox_screen_holds_doorbell() {  # <screen> <record-path>
  local screen=$1 line caps
  line=$(fm_task_inbox_doorbell_line "$2") || return 1
  caps=$(printf 'styled=0\ncursor=0\nidentity=0\nrows=40')
  fm_composer_screen_holds_only_text "$caps" "$screen" "$line"
}

# Whether the target's composer currently holds only this record's doorbell.
_fm_task_inbox_doorbell_pending() {  # <backend> <target> <record-path> [expected-label]
  local screen
  screen=$(fm_backend_capture "$1" "$2" 40 "${4:-}" 2>/dev/null) || return 1
  fm_task_inbox_screen_holds_doorbell "$screen" "$3"
}

# Delivery-busy for the shared queued-Enter verdict: the caller's semantic
# hint when it has one, else the backend's native state, else the target
# harness's rendered busy footer that bin/fm-tmux-lib.sh's submit core also reads.
_fm_task_inbox_busy_state() {  # <backend> <target> [expected-label] [hint] [harness] [screen]
  local busy screen visible harness=${5:-unknown}
  case "${4:-}" in
    busy|idle) printf '%s' "$4"; return 0 ;;
  esac
  busy=$(fm_backend_busy_state "$1" "$2" 2>/dev/null) || busy=unknown
  case "$busy" in
    busy|idle) printf '%s' "$busy"; return 0 ;;
  esac
  screen=${6:-}
  if [ -z "$screen" ]; then
    screen=$(fm_backend_capture "$1" "$2" 40 "${3:-}" 2>/dev/null) || { printf 'unknown'; return 0; }
  fi
  visible=$(printf '%s\n' "$screen" | grep -v '^[[:space:]]*$' | tail -12)
  case "$harness" in
    codex)
      if printf '%s\n' "$visible" \
        | grep -qiE '^[[:space:]]*•[[:space:]].*[[:space:]]\([0-9]+[[:space:]]*[smh]([[:space:]]+[0-9]+[[:space:]]*[smh])*[[:space:]]+•[[:space:]]+esc to interrupt\)[[:space:]]*$'; then
        printf 'busy'
      else
        printf 'unknown'
      fi
      ;;
    *)
      if printf '%s\n' "$visible" | fm_busy_lines_match "$harness"; then
        printf 'busy'
      else
        printf 'unknown'
      fi
      ;;
  esac
}

# Submit a doorbell already sitting in the composer by pressing Enter only,
# never typing again. A working pane gets exactly one Enter: some harnesses
# keep a queued line visible until the turn ends, and another Enter there
# would queue a duplicate. Otherwise Enter is retried, bounded, until the
# composer no longer holds the doorbell.
# Returns 0 once the composer no longer holds it, or when it is still visible
# on a working pane (fm_composer_queued_enter_verdict: accepted and queued),
# and 2 when an Enter was sent but the doorbell is still pending on a pane not
# known to be working. Internal status 5 means no Enter was successfully sent.
_fm_task_inbox_enter_pending_doorbell() {  # <backend> <target> <record-path> <label> <busy> <harness> <claim-state> <claim-task> <busy-result-var>
  local backend=$1 target=$2 rec=$3 label=$4 busy=$5 harness=$6 claim_state=$7 claim_task=$8 busy_result_var=$9
  local attempt=0 attempts=3 sent=0 claimed=0
  if [ "$busy" = busy ] && [ -n "$claim_state" ] && [ -n "$claim_task" ]; then
    fm_task_inbox_claim_busy_enter "$claim_state" "$claim_task" "$rec" || return 4
    claimed=1
  fi
  [ "$busy" != busy ] || attempts=1
  while [ "$attempt" -lt "$attempts" ]; do
    if [ "$attempt" -gt 0 ]; then
      busy=$(_fm_task_inbox_busy_state "$backend" "$target" "$label" '' "$harness")
      if [ "$busy" = busy ]; then
        [ -z "$busy_result_var" ] || printf -v "$busy_result_var" '%s' busy
        if [ "$sent" -eq 1 ] \
           && [ "$(fm_composer_queued_enter_verdict pending "$busy")" = empty ]; then
          if [ "$claimed" = 0 ] && [ -n "$claim_state" ] && [ -n "$claim_task" ]; then
            fm_task_inbox_claim_busy_enter "$claim_state" "$claim_task" "$rec" >/dev/null 2>&1 || :
          fi
          return 0
        fi
        if [ "$sent" -eq 0 ] && [ "$claimed" = 0 ] \
           && [ -n "$claim_state" ] && [ -n "$claim_task" ]; then
          fm_task_inbox_claim_busy_enter "$claim_state" "$claim_task" "$rec" || return 4
          claimed=1
        fi
        attempts=$((attempt + 1))
      fi
    fi
    fm_backend_send_key "$backend" "$target" Enter "$label" 2>/dev/null && sent=1
    sleep 0.4
    if ! _fm_task_inbox_doorbell_pending "$backend" "$target" "$rec" "$label"; then
      [ "$sent" -eq 1 ] || return 5
      return 0
    fi
    attempt=$((attempt + 1))
  done
  if [ "$sent" -ne 1 ]; then
    if [ "$claimed" = 1 ]; then
      _fm_task_inbox_release_busy_enter "$claim_state" "$claim_task" "$rec" || true
    fi
    return 5
  fi
  [ "$(fm_composer_queued_enter_verdict pending "$busy")" = empty ] && return 0
  return 2
}

# Ring the doorbell, best-effort, after checking endpoint liveness and the
# composer state.
# A composer holding only this inbox's exactly recognized doorbell is submitted
# again with Enter only, never retyped. An exact `pending` verdict protects any
# different text; pending-unproven and unknown composers still use the
# type-and-submit path by design, so a harness the classifier cannot read is
# not starved of steering.
# When that submit is not confirmed and the doorbell is left sitting in the
# composer, the same Enter-only recovery runs at once.
# A <busy-hint> of busy or idle is the caller's semantic verdict for the pane.
# busy is the watcher's working-pane mode: it only recovers a doorbell already
# in the composer and never types into a working agent.
# Returns 0 when submitted or queued, 1 when an exact pending verdict protects
# the composer, 2 when sending failed or the doorbell is still sitting
# unsubmitted, 3 when the endpoint is positively dead or missing, or 4 in busy
# mode when no doorbell was pending or its one-Enter claim already exists. No
# return value is delivery proof; the acknowledgement move is the only delivery
# signal. The optional busy-result variable receives the resolved classification
# for a recognized own doorbell.
fm_task_inbox_ring() {  # <backend> <target> <record-path> [expected-label] [busy-hint] [harness] [claim-state] [claim-task] [busy-result-var]
  local backend=$1 target=$2 rec=$3 label=${4:-} hint=${5:-} harness=${6:-unknown}
  local claim_state=${7:-} claim_task=${8:-} busy_result_var=${9:-}
  local line cstate verdict busy
  [ -z "$busy_result_var" ] || printf -v "$busy_result_var" '%s' unknown
  case "$(fm_backend_agent_state "$backend" "$target" 2>/dev/null || true)" in
    dead|missing) return 3 ;;
  esac
  if ! line=$(fm_task_inbox_doorbell_line "$rec"); then
    return 2
  fi
  if _fm_task_inbox_doorbell_pending "$backend" "$target" "$rec" "$label"; then
    busy=$(_fm_task_inbox_busy_state "$backend" "$target" "$label" "$hint" "$harness")
    [ -z "$busy_result_var" ] || printf -v "$busy_result_var" '%s' "$busy"
    _fm_task_inbox_recover_pending_doorbell "$backend" "$target" "$rec" "$label" \
      "$busy" "$claim_state" "$claim_task" "$harness" "$busy_result_var"
    return
  fi
  [ "$hint" != busy ] || return 4
  cstate=$(fm_backend_composer_state "$backend" "$target" "$label" 2>/dev/null) || cstate=unknown
  case "$cstate" in
    pending) return 1 ;;
  esac
  # Accepted residual race: terminal input and Enter are separate delivery
  # steps, so an agent exiting after the liveness check could leave a bare
  # shell only a suffix; the `: ` prefix protects complete lines only. Do not
  # add process-bound atomic delivery here unless an incident reopens this.
  if ! verdict=$(fm_backend_send_text_submit "$backend" "$target" "$line" 1 0.4 0.3 "$label" 2>/dev/null); then
    return 2
  fi
  # The verdict is read only to report a failed keystroke and to look for a
  # swallowed Enter; it is never delivery proof.
  [ "$verdict" != send-failed ] || return 2
  [ "$verdict" != empty ] || return 0
  if _fm_task_inbox_doorbell_pending "$backend" "$target" "$rec" "$label"; then
    busy=$(_fm_task_inbox_busy_state "$backend" "$target" "$label" "$hint" "$harness")
    [ -z "$busy_result_var" ] || printf -v "$busy_result_var" '%s' "$busy"
    _fm_task_inbox_recover_pending_doorbell "$backend" "$target" "$rec" "$label" \
      "$busy" "$claim_state" "$claim_task" "$harness" "$busy_result_var"
    return
  fi
  return 0
}

fm_task_inbox_is_fire_and_forget() {  # <record-path>
  local rec=$1
  if [ ! -f "$rec" ]; then
    rec="${rec%/*}/handled/${rec##*/}"
    [ -f "$rec" ] || return 1
  fi
  awk '
    $0 == "--" { exit }
    $0 == "delivery=fire-and-forget" { found=1 }
    END { exit(found ? 0 : 1) }
  ' "$rec"
}

# Oldest escalation-tracked unhandled record, or fail when none is due.
fm_task_inbox_oldest_unhandled() {  # <state-dir> <task-id>
  local dir best='' best_n=0 f n
  dir=$(fm_task_inbox_dir "$1" "$2")
  for f in "$dir"/*.msg; do
    [ -e "$f" ] || continue
    fm_task_inbox_is_fire_and_forget "$f" && continue
    n=$(fm_task_inbox_seq_of "${f##*/}") || continue
    if [ -z "$best" ] || [ "$n" -lt "$best_n" ]; then
      best=$f
      best_n=$n
    fi
  done
  [ -n "$best" ] || return 1
  printf '%s' "$best"
}

# The re-ring ladder decision for one task. Prints exactly one of:
#   quiet                     nothing due (healthy, within grace or spacing,
#                             or already escalated for the current oldest)
#   ring <record-path>        one doorbell re-ring is due
#   escalate <record-path> <count>   attempt budget spent; surface as stale
# An empty inbox also resets the ladder bookkeeping so the next message starts
# a fresh ladder.
fm_task_inbox_due_action() {  # <state-dir> <task-id>
  local dir oldest base now grace max ladder rec_base count last
  dir=$(fm_task_inbox_dir "$1" "$2")
  if ! oldest=$(fm_task_inbox_oldest_unhandled "$1" "$2"); then
    rm -f "$dir/.ring-state" "$dir/.escalated" 2>/dev/null || true
    printf 'quiet'
    return 0
  fi
  base=${oldest##*/}
  grace=$(fm_task_inbox_grace_secs)
  if [ "$(fm_path_age "$oldest")" -lt "$grace" ]; then
    printf 'quiet'
    return 0
  fi
  count=0
  last=0
  ladder=$(cat "$dir/.ring-state" 2>/dev/null || true)
  IFS=$(printf '\t') read -r rec_base count last <<EOF
$ladder
EOF
  if [ -n "$rec_base" ] && [ "$rec_base" != "$base" ]; then
    # A different oldest message: the previous ladder is stale. An absent
    # ladder is left alone so a dead-pane escalation, which never rings and so
    # never writes one, keeps its marker (the marker check below still ignores
    # a marker naming some other message).
    count=0
    last=0
    rm -f "$dir/.escalated" 2>/dev/null || true
  fi
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  if [ "$(cat "$dir/.escalated" 2>/dev/null || true)" = "$base" ]; then
    printf 'quiet'
    return 0
  fi
  max=$(fm_task_inbox_ring_max)
  if [ "$count" -ge "$max" ]; then
    printf 'escalate %s %s' "$oldest" "$count"
    return 0
  fi
  now=$(date +%s)
  if [ "$((now - last))" -lt "$grace" ]; then
    printf 'quiet'
    return 0
  fi
  printf 'ring %s' "$oldest"
}

# Advance the ladder after a delivery attempt. A failed ring or a composer-
# protected skip still consumes budget so neither an unreadable pane nor a
# permanently blocked composer can retry silently forever. A positively dead or
# missing endpoint never enters the ladder: the watcher escalates it directly.
# A concurrently removed inbox is a successful no-op; otherwise failure means
# the caller must surface the unwritable ladder while the record remains
# unhandled.
fm_task_inbox_record_ring() {  # <state-dir> <task-id> <record-path>
  local dir base ladder rec_base count last
  dir=$(fm_task_inbox_dir "$1" "$2")
  base=${3##*/}
  count=0
  ladder=$(cat "$dir/.ring-state" 2>/dev/null || true)
  IFS=$(printf '\t') read -r rec_base count last <<EOF
$ladder
EOF
  [ "$rec_base" = "$base" ] || count=0
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  [ -d "$dir" ] || return 0
  if ! { printf '%s\t%s\t%s\n' "$base" "$((count + 1))" "$(date +%s)" > "$dir/.ring-state"; } 2>/dev/null; then
    [ -d "$dir" ] || return 0
    return 1
  fi
}

# Claim the one Enter a busy pane's pending doorbell may get for <record>.
# Succeeds once per message; a later message, or a failed marker write, never
# claims, so an unwritable inbox degrades to waiting for the idle pane rather
# than pressing Enter on every poll.
fm_task_inbox_claim_busy_enter() {  # <state-dir> <task-id> <record-path>
  local dir base lock marker rc=1
  dir=$(fm_task_inbox_dir "$1" "$2")
  base=${3##*/}
  [ -d "$dir" ] || return 1
  lock="$dir/.busy-enter.lock"
  marker="$dir/.busy-enter"
  fm_task_inbox_lock_acquire "$lock" || return 1
  if [ "$(cat "$marker" 2>/dev/null || true)" != "$base" ]; then
    { printf '%s\n' "$base" > "$marker"; } 2>/dev/null && rc=0
  fi
  fm_lock_release "$lock" || true
  return "$rc"
}

_fm_task_inbox_release_busy_enter() {  # <state-dir> <task-id> <record-path>
  local dir base marker lock
  dir=$(fm_task_inbox_dir "$1" "$2")
  base=${3##*/}
  [ -d "$dir" ] || return 0
  marker="$dir/.busy-enter"
  lock="$dir/.busy-enter.lock"
  fm_task_inbox_lock_acquire "$lock" || return 1
  if [ "$(cat "$marker" 2>/dev/null || true)" = "$base" ]; then
    rm -f "$marker" 2>/dev/null || true
  fi
  fm_lock_release "$lock" || true
}

_fm_task_inbox_recover_pending_doorbell() {  # <backend> <target> <record-path> <label> <busy> <claim-state> <claim-task> <harness> <busy-result-var>
  local backend=$1 target=$2 rec=$3 label=$4 busy=$5 claim_state=$6 claim_task=$7 harness=$8 busy_result_var=$9
  local rc=0
  _fm_task_inbox_enter_pending_doorbell "$backend" "$target" "$rec" "$label" \
    "$busy" "$harness" "$claim_state" "$claim_task" "$busy_result_var" || rc=$?
  [ "$rc" != 5 ] || return 2
  return "$rc"
}

# Mark the current oldest as escalated after its stale wake is durably queued,
# suppressing another wake on later polls. Wake-before-marker ordering favors
# at-least-once recovery: a crash or marker failure can cause a rare duplicate;
# stuck-crewmate-recovery owns the message from here.
fm_task_inbox_record_escalated() {  # <state-dir> <task-id> <record-path>
  local dir
  dir=$(fm_task_inbox_dir "$1" "$2")
  [ -d "$dir" ] || return 0
  if ! { printf '%s\n' "${3##*/}" > "$dir/.escalated"; } 2>/dev/null; then
    [ -d "$dir" ] || return 0
    return 1
  fi
}
