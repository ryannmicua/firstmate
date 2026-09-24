#!/usr/bin/env bash
# bin/backends/paseo.sh - the Paseo runtime backend (EXPERIMENTAL).
#
# Paseo owns both the agent endpoint and the task worktree. This adapter uses
# only the CLI's public JSON/status surfaces: logs are timeline output, not a
# verified viewport, and agent liveness remains unverified because Paseo does
# not expose a worker pid through its CLI. Paseo never starts, stops, or
# restarts its daemon here; the daemon must already be reachable.

FM_BACKEND_PASEO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$FM_BACKEND_PASEO_ROOT}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

fm_backend_paseo_tool_check() {
  command -v paseo >/dev/null 2>&1 || { echo "error: backend=paseo selected but the 'paseo' CLI is not installed" >&2; return 1; }
  command -v jq >/dev/null 2>&1 || { echo "error: backend=paseo selected but 'jq' is not installed" >&2; return 1; }
}

fm_backend_paseo_runtime_check() {
  fm_backend_paseo_tool_check || return 1
  paseo daemon status >/dev/null 2>&1 || {
    echo "error: backend=paseo selected but 'paseo daemon status' failed; start the Paseo daemon outside firstmate" >&2
    return 1
  }
}

fm_backend_paseo_provider() { # <firstmate-harness>
  case "$1" in
    codex|opencode) printf '%s' "$1" ;;
    claude)
      local diagnostic
      diagnostic=$(paseo provider diagnostic claude 2>&1) || {
        echo "error: Paseo provider claude is not enabled on this host; pass a host diagnostic before using it" >&2
        return 1
      }
      if printf '%s\n' "$diagnostic" | grep -Eiq '^[[:space:]]*Status:[[:space:]]*(unavailable|disabled)[[:space:]]*$'; then
        echo "error: Paseo provider claude is not enabled on this host; pass a host diagnostic before using it" >&2
        return 1
      fi
      printf claude
      ;;
    pi-signed|muse|rovo|agy|pi|grok|kimi|cursor|gemini|omp)
      echo "error: Paseo has no supported provider for firstmate harness '$1'" >&2
      return 1
      ;;
    *) echo "error: Paseo cannot map unknown firstmate harness '$1' to a provider" >&2; return 1 ;;
  esac
}

fm_backend_paseo_create_task() { # <id> <source-clone> <brief> <harness> <model> <effort> <mode> <home-tag> <workspace-id> <env-file> [env key=value...]
  local id=$1 source=$2 brief=$3 harness=$4 model=${5:-} effort=${6:-} mode=${7:-} home_tag=${8:-} workspace_id=${9:-} env_file=${10:-}
  shift 10
  local provider default_branch raw json agent workspace worktree
  local -a args
  fm_backend_paseo_runtime_check || return 1
  : "$mode"
  provider=$(fm_backend_paseo_provider "$harness") || return 1
  if [ -n "$workspace_id" ]; then
    args=(run --background --workspace "$workspace_id" --provider "$provider"
      --label "fm-task=$id" --label "fm-home=$home_tag" --title "fm-$id" --json)
  else
    default_branch=$(git -C "$source" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || true)
    default_branch=${default_branch#origin/}
    [ -n "$default_branch" ] || default_branch=$(git -C "$source" symbolic-ref --short HEAD 2>/dev/null || true)
    [ -n "$default_branch" ] || { echo "error: could not resolve the source clone's default branch for Paseo task $id" >&2; return 1; }
    args=(run --background --new-workspace worktree --base "origin/$default_branch"
      --worktree-slug "fm-$id" --cwd "$source" --provider "$provider"
      --label "fm-task=$id" --label "fm-home=$home_tag" --title "fm-$id" --json)
  fi
  [ -n "$model" ] && [ "$model" != default ] && args+=(--model "$model")
  [ -n "$effort" ] && [ "$effort" != default ] && args+=(--thinking "$effort")
  case "$provider" in
    opencode) args+=(--mode build) ;;
    codex) args+=(--mode auto-review) ;;
  esac
  if [ -n "$env_file" ]; then
    if paseo run --help 2>&1 | grep -F -- '--env-file' >/dev/null; then
      args+=(--env-file "$env_file")
    else
      echo "error: Paseo CLI has no native --env-file transport; refusing to launch task $id without delivering its allowlisted environment" >&2
      return 1
    fi
  fi
  for env_value in "$@"; do args+=(--env "$env_value"); done
  args+=("$brief")
  raw=$(env -u PASEO_AGENT_ID paseo "${args[@]}" 2>&1) || { printf '%s\n' "$raw" >&2; return 1; }
  json=$(printf '%s\n' "$raw" | awk 'found || /^\{/{found=1; print}')
  agent=$(printf '%s\n' "$json" | jq -r '.agentId // .id // empty' 2>/dev/null)
  workspace=$(printf '%s\n' "$json" | jq -r '.workspaceId // .workspace.id // .workspace // empty' 2>/dev/null)
  [ -n "$workspace" ] || workspace=$(printf '%s\n' "$raw" | sed -n 's/.*Created workspace \([^[:space:]]*\).*/\1/p' | tail -n 1)
  worktree=$(printf '%s\n' "$json" | jq -r '.worktreePath // .worktree // .cwd // empty' 2>/dev/null)
  [ -n "$agent" ] && [ -n "$workspace" ] && [ -n "$worktree" ] || {
    echo "error: Paseo did not return agent id, workspace id, and worktree path for task $id" >&2
    printf '%s\n' "$raw" >&2
    return 1
  }
  printf '%s\t%s\t%s' "$agent" "$workspace" "$worktree"
}

fm_backend_paseo_capture() { # <agent-id> <lines>
  local id=$1 lines=${2:-40} raw
  fm_backend_paseo_tool_check || return 1
  raw=$(paseo logs "$id" --tail "$lines" --json) || return 0
  printf '%s\n' "$raw" | jq -r 'if type == "array" then .[] | if type == "string" then . else (.text // .content // .message // tostring) end else (.text // .content // .message // tostring) end' 2>/dev/null || true
}

fm_backend_paseo_status() {
  fm_backend_paseo_tool_check || return 1
  paseo inspect "$1" --json | jq -r '(.lastStatus // .LastStatus // .status // .Status // .agent.lastStatus // .agent.status // empty) | ascii_downcase' 2>/dev/null
}

fm_backend_paseo_busy_state() {
  case "$(fm_backend_paseo_status "$1" 2>/dev/null || true)" in
    initializing|running|working|busy) printf busy ;;
    idle|closed|completed|failed|canceled|cancelled|stopped|archived) printf idle ;;
    *) printf unknown ;;
  esac
}

fm_backend_paseo_stop_status_proof() { # <agent-id> <timeout> <poll>
  local id=$1 timeout=${2:-30} poll=${3:-0.5} elapsed=0 status
  fm_backend_paseo_tool_check || return 1
  paseo stop "$id" >/dev/null 2>&1 || return 1
  while :; do
    status=$(fm_backend_paseo_busy_state "$id")
    [ "$status" = idle ] && return 0
    awk -v e="$elapsed" -v t="$timeout" 'BEGIN{exit !(e < t)}' || break
    sleep "$poll"
    elapsed=$(awk -v e="$elapsed" -v p="$poll" 'BEGIN{printf "%.3f", e + p}')
  done
  return 1
}

fm_backend_paseo_archive_agent() {
  fm_backend_paseo_tool_check || return 1
  paseo archive "$1" >/dev/null
}

fm_backend_paseo_send_text_submit() { # <agent-id> <text> ...
  local id=$1 text=$2
  fm_backend_paseo_tool_check || return 1
  paseo send "$id" --no-wait "$text"
}

fm_backend_paseo_send_key() { # <agent-id> <key>
  case "$2" in
    C-c|ctrl+c|Ctrl-c|Ctrl-C) fm_backend_paseo_tool_check && paseo stop "$1" ;;
    *) echo "error: Paseo cannot express key '$2'; only interrupt maps to paseo stop" >&2; return 1 ;;
  esac
}

fm_backend_paseo_kill() { # <agent-id> <workspace-id>
  local agent=$1 workspace=${2:-}
  fm_backend_paseo_archive_agent "$agent" || return 1
  [ -n "$workspace" ] || return 0
  paseo workspace archive "$workspace" >/dev/null
}

fm_backend_paseo_agent_state() { printf unverified; }

fm_backend_paseo_target_exists() {
  fm_backend_paseo_tool_check || return 1
  paseo inspect "$1" --json >/dev/null 2>&1
}
