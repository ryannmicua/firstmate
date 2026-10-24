# Attention feed verification

Last tested: 2026-10-24.

From the run worktree, create .validation-tmp and run the evidence script drive_attention.py with Python 3.
It requires Bash, jq, and tasks-axi on PATH, clears inherited fleet/backlog overrides, and creates only disposable isolated homes inside .validation-tmp.
It invokes the real product CLI and saves JSON outputs plus a full command transcript here.
It verifies lifecycle, retries, deferral, legacy dates, keyed opening/resolution, delayed large ledgers, invalid continuations, argument guards, and unchanged files/directories with a registered remote secondmate.
The drivers clean up their own homes in finally blocks.
No primary launch, worker launch, or operator data is needed.

Run the focused regression with TMPDIR set to the worktree's .validation-tmp directory: bash tests/fm-attention.test.sh.
The suite uses stand-ins for fleet tools and for the adapter and does not establish live Beads integration.

For Beads, provide a Beads-capable tasks-axi plus real bd and run drive_beads.py (update its disposable bd binary path as needed).
This run downloaded bd v1.3.2 locally and initialized an embedded database successfully; installed and latest upstream tasks-axi 0.2.6 reject the beads backend.
See beads-cli-transcript.json and adapter-capability.json.
Remove the disposable .validation-tmp directory when finished; preserve evidence here.
