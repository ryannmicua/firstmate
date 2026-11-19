### AgentMail isolated CLI validation

Last tested: 2026-11-19.

Run from the gate worktree with Python 3, curl, jq and Bash available. Create `.agentmail-live/`, then run the retained `drive-agentmail-local.py` from the evidence directory. The script uses the current directory as its code root, creates a private FM_HOME in `.agentmail-live/home`, binds an ephemeral localhost HTTP server, executes the real `fm-agentmail-{check,send,daily}.sh` helpers and stops the server before returning. It saves scenario transcripts, HTTP requests and generated inbox notes to this run's evidence directory. Remove `.agentmail-live/` after completion. Never use a real API key or real home for this recipe.

Independent expected behavior comes from the supplied owner intent, documented local CLI contracts, and AgentMail's list/get HTTP contracts:
- https://docs.agentmail.to/api-reference/inboxes/messages/list.md
- https://docs.agentmail.to/api-reference/inboxes/messages/get.md

The emulator represents the remote service only; it does not replace curl, the scripts, inbox persistence, registration, or background poll execution. Assertions reject wrong trust, wrong recipients, timestamp-based discovery loss, duplicate captures, duplicate daily sends, and retries after uncertain delivery. This demonstrates local product behavior with synthetic inputs, not real mailbox delivery, DNS authentication, or the operator's account setup.

Also run the focused existing regression file: `TMPDIR="$PWD/.agentmail-live/unit-tmp" bash tests/fm-agentmail.test.sh`. Its fake curl evidence is supplemental and is not classified as live validation.

No UI changes are present; CLI transcripts, actual payloads, and persisted notes are the reviewer-visible product artifacts.
