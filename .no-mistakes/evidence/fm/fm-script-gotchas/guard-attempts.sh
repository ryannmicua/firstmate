#!/usr/bin/env bash
set -eu
LAB=$PWD/.test-tmp/guard-home
bin/fm-lab-home.sh create "$LAB"
trap 'rm -rf "$LAB"' EXIT
unset FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
for script in fm-send fm-control; do
  echo "ATTEMPT: $script with no FM_HOME"
  if env -u FM_HOME "bin/$script.sh" some-task interrupt; then exit 1; else echo "refusal exit=$?"; fi
done
mkdir -p "$LAB/state/parent-route" "$LAB/data/.parent-route"
echo 'ATTEMPT: disposable remote parent-route retirement'
if FM_HOME="$LAB" FM_STATE_OVERRIDE="$LAB/state/parent-route" FM_DATA_OVERRIDE="$LAB/data/.parent-route" bin/fm-teardown.sh remote-task; then exit 1; else echo "refusal exit=$?"; fi
