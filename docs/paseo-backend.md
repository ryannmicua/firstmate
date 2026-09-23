# Paseo Runtime Backend

Paseo is an experimental, explicit-only runtime backend for Codex and OpenCode workers.
It owns the agent endpoint and isolated task worktree through `paseo run --new-workspace worktree`.

## Setup

Install Paseo and `jq`, then ensure the existing daemon answers `paseo daemon status`.
Firstmate never starts, stops, or restarts the Paseo daemon.
Select it with `config/backend`, `FM_BACKEND=paseo`, or an explicitly authorized `--backend paseo`.
Paseo is never auto-detected and never supports secondmate spawns.

## Limits

`codex` and `opencode` map directly to Paseo providers.
Claude is accepted only when `paseo provider diagnostic claude` succeeds on the host.
Absent providers are rejected by name rather than substituted.
Workers are root agents created with `env -u PASEO_AGENT_ID`.
Each task records its labeled agent, workspace, and worktree identities.
Logs are timeline output, not a verified visible viewport, and agent liveness remains `unverified` because Paseo exposes no worker pid.
Interrupt maps to `paseo stop`; unsupported keys and stop-proving exit/relaunch verbs are rejected.
Teardown archives the agent and then its separate workspace record.

## Verification

The adapter contract is implemented in [`bin/backends/paseo.sh`](../bin/backends/paseo.sh), with dispatch in [`bin/fm-backend.sh`](../bin/fm-backend.sh).
Current host evidence belongs in [`verification/runtime-backends.md`](verification/runtime-backends.md#paseo).
