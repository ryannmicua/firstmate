# Paseo Runtime Backend

Paseo is an experimental, explicit-only runtime backend for Codex, OpenCode, and host-diagnostic-gated Claude workers.
It owns the agent endpoint and isolated task worktree through `paseo run --background --new-workspace worktree`.

## Setup

Install Paseo and `jq`, then ensure the existing daemon answers `paseo daemon status`.
Firstmate never starts, stops, or restarts the Paseo daemon.
Select it with `config/backend`, `FM_BACKEND=paseo`, or an explicitly authorized `--backend paseo`.
Paseo is never auto-detected and never supports secondmate spawns.

## Limits

`codex` and `opencode` map directly to Paseo providers.
Claude is accepted only when its host diagnostic has a recognized positive status and Paseo reports the provider available and enabled.
Absent providers are rejected by name rather than substituted.
Workers are root agents created with `env -u PASEO_AGENT_ID`.
Each task records its labeled agent, workspace, and worktree identities.
When launch-environment filtering is enabled, set allowlisted values are passed to Paseo as individual `--env NAME=value` arguments.
`PASEO_AGENT_ID` is Paseo-owned and is never forwarded, and values containing CR or LF are rejected to protect daemon environment parsing.
These values are visible in process listings on the host running the Paseo daemon.
Logs are timeline output, not a verified visible viewport, and agent liveness remains `unverified` because Paseo exposes no worker pid.
Interrupt maps to `paseo stop`; exit accepts only a native `closed` or `archived` status as stop proof, otherwise archives the agent and verifies terminal status.
After a successful Paseo run, an aborted Firstmate spawn archives the agent and workspace only when Git proves the worktree clean; dirty or uninspectable worktrees are retained with their IDs and a reason for manual reconciliation.
If `paseo run` fails after reporting a created workspace, Firstmate reports its ID and leaves that workspace for manual reconciliation.
Teardown archives the agent and then its separate workspace record.

## Verification

The adapter contract is implemented in [`bin/backends/paseo.sh`](../bin/backends/paseo.sh), with dispatch in [`bin/fm-backend.sh`](../bin/fm-backend.sh).
Current host evidence belongs in [`verification/runtime-backends.md`](verification/runtime-backends.md#paseo).
