# AgentMail local live validation

Last tested: 2026-11-19.

Run from the gate worktree:

```sh
bash tests/fm-agentmail.test.sh
python3 ~/.no-mistakes/evidence/01M7SA8J40GG7DT9PWBN5WNJ80/agentmail-live.py
```

The Python driver starts a disposable localhost HTTP API and executes the real Bash helpers, curl, jq, inbox-note writer, and check registrar.
It seeds invented owner addresses and an invented key inside a disposable directory under the worktree.
It retains CLI output, HTTP requests, generated inbox notes, and daily-send records in the evidence directory, then shuts down the API, disarms the background check, waits for child processes, and deletes the disposable home.
Its independent expectations are the supplied intent's two-owner routing, verified inbound trust, exact one-send recipient authorization, and at-most-once daily constraint, together with the documented note and retry contracts.
The API emulator deliberately paginates, enforces spam/blocked/unauthenticated discovery flags, drops a send response, and returns a definitive rejection.

Safe: rerun these local synthetic scenarios without a real account or real recipients.
Real delivery is outside this recipe: do not point it at an operator home or production endpoint.
No real AgentMail account, external mailbox, TLS service endpoint, or model interpretation of a captured task was exercised.
The existing shell suite uses a curl replacement; its passing results are supplementary regression evidence and are not classified as live scenarios.
There is no browser or rendered application surface in this CLI-only change; retained CLI and persisted-note output are the reviewer-visible product artifacts.
