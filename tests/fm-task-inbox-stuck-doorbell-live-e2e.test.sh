#!/usr/bin/env bash
# tests/fm-task-inbox-stuck-doorbell-live-e2e.test.sh - live guard for a
# steering doorbell left sitting in a real worker's composer
# (live-harness-optin family).
#
# A harness can swallow the Enter that submits the doorbell: live codex-cli
# turns an Enter that arrives in the same input read as the typed line into a
# newline, idle and mid-turn, and the line then sits unsubmitted until someone
# presses Enter. Whether a composer still holds only our own line is a
# rendered-surface question, so per .agents/skills/firstmate-coding-guidelines
# it is proven here against every INSTALLED verified harness on every
# requested backend, and fails naming the harness and version.
#
# For each harness and backend it runs three phases, each ending only when the
# worker both ACTS on its record (creates a named file) and ACKNOWLEDGES it
# (the mv into handled/):
#   idle-send   the doorbell typed with an immediate Enter on an idle worker;
#               reports whether the Enter was swallowed (exposure), then plays
#               the watcher's role until the record is handled;
#   idle-stuck  the doorbell typed with no Enter at all; the guard requires
#               fm_task_inbox_screen_holds_doorbell to recognize it, then
#               requires one watcher-mode ring to resubmit it without typing;
#   mid-turn    the doorbell typed with an immediate Enter while the worker
#               runs a long shell command; reports exposure, then plays the
#               watcher's role (one Enter while working, ordinary rings once
#               idle) until the record is handled.
#
# Run explicitly with FM_STUCK_DOORBELL_LIVE=1. It spends a few real model
# turns per harness and backend. Restrict with
# FM_STUCK_DOORBELL_LIVE_HARNESSES="codex ..." and
# FM_STUCK_DOORBELL_LIVE_BACKENDS="tmux herdr" (default both; herdr runs only
# through bin/fm-herdr-lab.sh, or HERDR_LAB_HELPER, in a named non-default lab
# session). FM_STUCK_DOORBELL_LIVE_TIMEOUT bounds each phase (seconds,
# default 240). An absent harness or backend is reported and skipped; a run
# that verified nothing fails. Record the dated per-harness result in
# docs/verification/runtime-backends.md ("Swallowed-Enter recovery").
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fm_live_gate opt-in FM_STUCK_DOORBELL_LIVE tmux

unset NO_MISTAKES_GATE

LAB=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-stuck-doorbell-live.XXXXXX")
TIMEOUT=${FM_STUCK_DOORBELL_LIVE_TIMEOUT:-240}
BACKENDS=${FM_STUCK_DOORBELL_LIVE_BACKENDS:-tmux herdr}
HARNESSES=${FM_STUCK_DOORBELL_LIVE_HARNESSES:-claude codex opencode pi grok kimi muse}
LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
ORIGINAL_PATH=$PATH
SOCKET="fm-stuck-doorbell-$$"
HERDR_LAB_SESSION=
CHECKED=0
FAILED=0

pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }
bad() { FAILED=1; printf 'not ok - %s\n' "$1" >&2; }

cleanup() {
  local rc=$?
  trap - EXIT
  PATH=$ORIGINAL_PATH tmux -L "$SOCKET" kill-server 2>/dev/null || true
  if [ -n "$HERDR_LAB_SESSION" ] \
    && ! PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$HERDR_LAB_SESSION"; then
    rc=1
  fi
  rm -rf "$LAB"
  exit "$rc"
}
trap cleanup EXIT

# Every bare `tmux` the backend libraries run is pinned to the private socket.
mkdir -p "$LAB/bin" "$LAB/fm-home"
REAL_TMUX=$(command -v tmux)
cat > "$LAB/bin/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$LAB/bin/tmux"
PATH="$LAB/bin:$PATH"
tmux new-session -d -s stuck -x 160 -y 50 -c "$ROOT"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-task-inbox-lib.sh"

lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }

# Herdr is reached only through the lab helper: the shim refuses any call that
# does not name the lab session, then hands the rest to `fm-herdr-lab.sh run`.
herdr_lab_up() {
  local helper_name
  command -v herdr >/dev/null 2>&1 || { note "backend absent, not verified here: herdr"; return 1; }
  command -v jq >/dev/null 2>&1 || { note "jq absent; herdr not verified here"; return 1; }
  [ -x "$LAB_HELPER" ] || { bad "herdr: the lab helper is not executable at $LAB_HELPER"; return 1; }
  # shellcheck source=tests/herdr-test-safety.sh
  . "$ROOT/tests/herdr-test-safety.sh"
  herdr_forget_inherited_pane
  helper_name=$(PATH="$ORIGINAL_PATH" "$LAB_HELPER" name stuck-doorbell) || { bad "herdr: could not name a lab session"; return 1; }
  HERDR_LAB_SESSION=$helper_name
  cat > "$LAB/bin/herdr" <<EOF
#!/usr/bin/env bash
set -u
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ] && [ "\${args[\$((n-1))]}" = "$HERDR_LAB_SESSION" ]; then
  exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$HERDR_LAB_SESSION" "\${args[@]:0:\$((n-2))}"
fi
echo "stuck-doorbell guard: herdr call refused outside $HERDR_LAB_SESSION" >&2
exit 98
EOF
  chmod +x "$LAB/bin/herdr"
  PATH="$ORIGINAL_PATH" "$LAB_HELPER" provision "$HERDR_LAB_SESSION" \
    || { bad "herdr: could not provision the isolated lab session"; return 1; }
  fm_backend_source herdr || { bad "herdr: the backend adapter did not load"; return 1; }
  return 0
}

harness_version() {  # <binary>
  PATH=$ORIGINAL_PATH "$1" --version 2>/dev/null | head -1 || printf 'version-unknown'
}

# The unattended-autonomy posture bin/fm-spawn.sh uses, launched from the repo
# root (already trusted on an operator machine) but kept from acting on this
# repository's own supervisor contract: project hooks, plugins, extensions, and
# instruction files are switched off wherever the harness has a switch, and
# FM_HOME points any firstmate script a worker still runs at the lab.
# Claude has no OAuth-compatible way to skip CLAUDE.md, so only its project
# settings and hooks are skipped; the explicit steer keeps it on task.
launch_cmd() {  # <name>
  local env="FM_HOME='$LAB/fm-home'"
  case "$1" in
    claude) printf '%s' "$env CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions --setting-sources user --settings '{\"feedbackDrafts\":\"off\"}'" ;;
    codex) printf '%s' "$env codex --dangerously-bypass-approvals-and-sandbox --disable hooks -c project_doc_max_bytes=0" ;;
    opencode) printf '%s' "$env OPENCODE_DISABLE_PROJECT_CONFIG=1 OPENCODE_DISABLE_CLAUDE_CODE=1 OPENCODE_CONFIG_CONTENT='{\"permission\":{\"*\":\"allow\"}}' opencode" ;;
    pi|pi-signed) printf '%s' "$env $1 --no-context-files --no-extensions" ;;
    grok) printf '%s' "$env grok --always-approve" ;;
    kimi) printf '%s' "$env kimi --auto" ;;
    muse) printf '%s' "$env MUSE_EXPERIMENTAL_FOREIGN_PERSONAL_CONTEXT_KILL=on muse --yolo" ;;
    *) return 1 ;;
  esac
}

# Launch <harness> on <backend> and print its target.
launch() {  # <backend> <harness>
  local backend=$1 name=$2 cmd ws pane
  cmd=$(launch_cmd "$name") || return 1
  case "$backend" in
    tmux)
      tmux new-window -d -t stuck: -n "sd-$name" -c "$ROOT" -- bash -lc "$cmd" || return 1
      printf 'stuck:sd-%s' "$name"
      ;;
    herdr)
      ws=$(lab workspace create --cwd "$ROOT" --label "sd-$name" --no-focus) || return 1
      pane=$(printf '%s' "$ws" | jq -er '.result.root_pane.pane_id') || return 1
      lab pane run "$pane" "$cmd" >/dev/null || return 1
      printf '%s:%s' "$HERDR_LAB_SESSION" "$pane"
      ;;
  esac
}

close_target() {  # <backend> <target>
  case "$1" in
    tmux) tmux kill-window -t "$2" 2>/dev/null || true ;;
    herdr) lab pane close "${2#*:}" >/dev/null 2>&1 || true ;;
  esac
}

type_literal() {  # <backend> <target> <text>
  case "$1" in
    tmux) tmux send-keys -t "$2" -l "$3" ;;
    herdr) fm_backend_herdr_send_literal "$2" "$3" ;;
  esac
}

screen_of() {  # <backend> <target>
  fm_backend_capture "$1" "$2" 40 2>/dev/null || true
}

# Working, by the backend's native state or the harness's own rendered busy
# footer - the same two sources the watcher consults.
is_busy() {  # <backend> <target> <harness>
  [ "$(fm_backend_busy_state "$1" "$2" 2>/dev/null)" = busy ] && return 0
  screen_of "$1" "$2" | grep -v '^[[:space:]]*$' | tail -12 | fm_busy_lines_match "$3"
}

wait_ready() {  # <backend> <target>
  local i=0 verdict=unknown
  while [ "$i" -lt 60 ]; do
    verdict=$(fm_backend_composer_state "$1" "$2" 2>/dev/null) || verdict=unknown
    [ "$verdict" = empty ] && return 0
    sleep 1
    i=$((i + 1))
  done
  [ "$verdict" != pending ]
}

wait_idle() {  # <backend> <target> <harness>
  local i=0 quiet=0
  while [ "$i" -lt "$TIMEOUT" ]; do
    if is_busy "$1" "$2" "$3"; then quiet=0; else quiet=$((quiet + 1)); fi
    [ "$quiet" -ge 4 ] && return 0
    sleep 1
    i=$((i + 1))
  done
  return 1
}

# Play the watcher's role until <record> is handled and <acted> exists: a
# working pane gets one Enter for its own stuck doorbell; an idle pane gets an
# ordinary watcher-mode ring every 20 seconds. Prints how it recovered.
watch_until_handled() {  # <backend> <target> <harness> <record> <acted>
  local backend=$1 target=$2 harness=$3 rec=$4 acted=$5 i=0 claimed=0 last=0 how='' rc
  local handled="${rec%/*}/handled/${rec##*/}"
  while [ "$i" -lt "$TIMEOUT" ]; do
    if [ -f "$handled" ] && [ -e "$acted" ]; then
      printf '%s' "${how:-its own submit}"
      return 0
    fi
    if [ -f "$rec" ]; then
      if is_busy "$backend" "$target" "$harness"; then
        if [ "$claimed" -eq 0 ] && fm_task_inbox_screen_holds_doorbell "$(screen_of "$backend" "$target")" "$rec"; then
          claimed=1
          rc=0
          fm_task_inbox_ring "$backend" "$target" "$rec" '' busy || rc=$?
          how="${how:+$how+}busy-enter(rc=$rc)"
        fi
      elif [ $((i - last)) -ge 20 ]; then
        rc=0
        fm_task_inbox_ring "$backend" "$target" "$rec" '' idle || rc=$?
        how="${how:+$how+}idle-ring(rc=$rc)"
        last=$i
      fi
    fi
    sleep 1
    i=$((i + 1))
  done
  printf '%s' "${how:-none}"
  return 1
}

check_one() {  # <backend> <harness>
  local backend=$1 name=$2 version target home state rec line acted how stuck rc label
  version=$(harness_version "$name")
  label="$name ($version) on $backend"
  target=$(launch "$backend" "$name") || { bad "$label: could not launch"; return 0; }
  if ! wait_ready "$backend" "$target"; then
    bad "$label: composer stayed visibly pending before any doorbell"
    close_target "$backend" "$target"
    return 0
  fi
  home="$LAB/$backend-$name"; state="$home/state"; mkdir -p "$state"

  # idle-send: an immediate Enter, the way a lagging harness reads it.
  acted="$home/acted-idle-send"
  rec=$(fm_task_inbox_write "$state" t1 "Live check: run exactly this shell command now: touch $acted - then follow the mv instruction you were given for this message.")
  line=$(fm_task_inbox_doorbell_line "$rec")
  type_literal "$backend" "$target" "$line"; fm_backend_send_key "$backend" "$target" Enter
  sleep 2
  stuck=no
  fm_task_inbox_screen_holds_doorbell "$(screen_of "$backend" "$target")" "$rec" && stuck=yes
  if how=$(watch_until_handled "$backend" "$target" "$name" "$rec" "$acted"); then
    pass "$label idle-send: Enter swallowed=$stuck; handled via ${how}"
  else
    bad "$label idle-send: not handled within ${TIMEOUT}s (Enter swallowed=$stuck; attempts ${how})"
    screen_of "$backend" "$target" | grep '[^[:space:]]' | tail -8 | sed 's/^/#   /' >&2
  fi
  wait_idle "$backend" "$target" "$name" || note "$label: still working after idle-send"

  # idle-stuck: no Enter at all; recognition must hold and the recovery ring
  # must resubmit it with Enter only.
  acted="$home/acted-idle-stuck"
  rec=$(fm_task_inbox_write "$state" t1 "Live check: run exactly this shell command now: touch $acted - then follow the mv instruction you were given for this message.")
  line=$(fm_task_inbox_doorbell_line "$rec")
  type_literal "$backend" "$target" "$line"
  sleep 2
  if ! fm_task_inbox_screen_holds_doorbell "$(screen_of "$backend" "$target")" "$rec"; then
    bad "$label idle-stuck: a doorbell sitting in the composer was not recognized as our own"
    screen_of "$backend" "$target" | grep '[^[:space:]]' | tail -8 | sed 's/^/#   /' >&2
  else
    rc=0
    fm_task_inbox_ring "$backend" "$target" "$rec" '' idle || rc=$?
    if [ "$rc" != 0 ]; then
      bad "$label idle-stuck: the Enter-only resubmit left the doorbell pending (rc=$rc)"
    elif how=$(watch_until_handled "$backend" "$target" "$name" "$rec" "$acted"); then
      CHECKED=$((CHECKED + 1))
      pass "$label idle-stuck: recognized and resubmitted with Enter only; handled after ${how}"
    else
      bad "$label idle-stuck: resubmitted but not handled within ${TIMEOUT}s"
    fi
  fi
  wait_idle "$backend" "$target" "$name" || note "$label: still working after idle-stuck"

  # mid-turn: the same immediate Enter while a long shell command runs.
  fm_backend_send_text_submit "$backend" "$target" \
    "Use your shell tool to run the command  sleep 45  and wait for it to finish, then reply with the single word SLEPT." \
    3 0.4 0.4 >/dev/null 2>&1 || true
  rc=1
  for _ in $(seq 1 60); do
    if is_busy "$backend" "$target" "$name"; then rc=0; break; fi
    sleep 1
  done
  [ "$rc" = 0 ] || note "$label mid-turn: the long turn never read as working; the phase may not be mid-turn"
  sleep 8
  acted="$home/acted-mid-turn"
  rec=$(fm_task_inbox_write "$state" t1 "Live check: run exactly this shell command now: touch $acted - then follow the mv instruction you were given for this message.")
  line=$(fm_task_inbox_doorbell_line "$rec")
  type_literal "$backend" "$target" "$line"; fm_backend_send_key "$backend" "$target" Enter
  sleep 2
  stuck=no
  fm_task_inbox_screen_holds_doorbell "$(screen_of "$backend" "$target")" "$rec" && stuck=yes
  if how=$(watch_until_handled "$backend" "$target" "$name" "$rec" "$acted"); then
    pass "$label mid-turn: Enter swallowed=$stuck; handled via ${how}"
  else
    bad "$label mid-turn: not handled within ${TIMEOUT}s (Enter swallowed=$stuck; attempts ${how})"
    screen_of "$backend" "$target" | grep '[^[:space:]]' | tail -8 | sed 's/^/#   /' >&2
  fi
  close_target "$backend" "$target"
}

for backend in $BACKENDS; do
  case "$backend" in
    tmux) ;;
    herdr) herdr_lab_up || continue ;;
    *) note "backend not covered by this guard: $backend"; continue ;;
  esac
  for h in $HARNESSES; do
    if PATH=$ORIGINAL_PATH command -v "$h" >/dev/null 2>&1; then
      check_one "$backend" "$h"
    else
      note "harness absent, not verified here: $h"
    fi
  done
done

if [ "$FAILED" -ne 0 ]; then
  printf 'not ok - live stuck-doorbell guard found failures above\n' >&2
  exit 1
fi
if [ "$CHECKED" -eq 0 ]; then
  printf 'not ok - live stuck-doorbell guard verified nothing (no harness installed?)\n' >&2
  exit 1
fi
pass "live stuck-doorbell guard: $CHECKED harness/backend pair(s) recovered a doorbell left in the composer"
