#!/usr/bin/env bash
set -eu
ROOT=$PWD
LAB=$ROOT/.test-tmp/live-home
bin/fm-lab-home.sh create "$LAB"
SOCKET=$ROOT/.test-tmp/as
trap 'tmux -S "$SOCKET" kill-server 2>/dev/null || true; rm -rf "$LAB"; rm -f "$SOCKET"' EXIT
tmux -S "$SOCKET" new-session -d -s fm-lab-archive -n keeper -c "$LAB" 'sleep 120'
export TMUX="$SOCKET,$(tmux -S "$SOCKET" display-message -p '#{pid}'),0"
tmux -S "$SOCKET" new-window -d -t fm-lab-archive -n fm-archive-task -c "$LAB" 'sleep 120'

export FM_HOME=$LAB GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
export FM_PROCEVENT_CLAIM_ROOT=$LAB/state/claims
id=archive-task
mkdir -p "$LAB/data/$id/steers" "$LAB/state/$id.inbox/handled" "$LAB/projects/fixture"
git init -q "$LAB/projects/fixture"
printf 'window=fm-lab-archive:fm-%s\nendpoint_task_id=%s\nworktree=%s/absent-worker\nproject=%s/projects/fixture\nkind=scout\n' "$id" "$id" "$LAB" "$LAB" > "$LAB/state/$id.meta"
printf 'completed disposable report\n' > "$LAB/data/$id/report.md"
printf 'first steer\r\nno trailing newline' > "$LAB/state/$id.inbox/handled/001.msg"
printf 'second steer\n' > "$LAB/state/$id.inbox/handled/002.msg"
printf 'older different content\n' > "$LAB/data/$id/steers/001.msg"
cp "$LAB/state/$id.inbox/handled/002.msg" "$LAB/data/$id/steers/002.msg"
printf 'unhandled\n' > "$LAB/state/$id.inbox/003.msg"
"$ROOT/bin/fm-captain-hold.sh" complete "$id" --none
# A regular file at the archive destination actively provokes mkdir failure.
mv "$LAB/data/$id/steers" "$LAB/data/$id/old-steers"
printf 'blocked destination' > "$LAB/data/$id/steers"
if "$ROOT/bin/fm-teardown.sh" "$id" > "$LAB/refusal.log" 2>&1; then echo 'FAIL: blocked archive succeeded'; exit 1; fi
cat "$LAB/refusal.log"
rg -q "could not archive handled steers" "$LAB/refusal.log"
[ -f "$LAB/state/$id.inbox/handled/001.msg" ]
echo 'OBSERVED: archive failure retained handled inbox and task records'
rm "$LAB/data/$id/steers"
mv "$LAB/data/$id/old-steers" "$LAB/data/$id/steers"
tmux -S "$SOCKET" new-window -d -t fm-lab-archive -n fm-archive-task -c "$LAB" 'sleep 120'
"$ROOT/bin/fm-teardown.sh" "$id"
if tmux -S "$SOCKET" has-session -t fm-lab-archive:fm-archive-task 2>/dev/null; then exit 1; fi
[ ! -e "$LAB/state/$id.inbox" ]
cmp "$LAB/data/$id/steers/001.msg.1" <(printf 'first steer\r\nno trailing newline')
cmp "$LAB/data/$id/steers/001.msg" <(printf 'older different content\n')
cmp "$LAB/data/$id/steers/002.msg" <(printf 'second steer\n')
[ ! -e "$LAB/data/$id/steers/002.msg.1" ]
[ ! -e "$LAB/data/$id/steers/003.msg" ]
cp "$LAB/data/$id/steers/001.msg.1" /home/rgm/.no-mistakes/evidence/01M4HG8J0V5TEX93CF7T52EKM0/archived-steer.msg
echo 'OBSERVED: retry archived exact bytes, preserved collision, deduplicated identical copy, excluded unhandled message, removed inbox'
