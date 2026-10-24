# Session activity CLI verification

Last tested: 2026-10-25.

Run from the gate worktree using `python3 <evidence-directory>/live-attention.py` after creating `.test-tmp` inside the worktree.
The driver creates an isolated FM_HOME under `.test-tmp`, removes inherited FM/task addressing overrides, uses the real markdown tasks-axi adapter, and invokes production scripts through Bash without fake binaries.
It seeds the documented ledger protocol and session timestamps, invokes the real ledger producer and captain-hold command, then reads `bin/fm-attention.sh --json`.
It asserts ordering, boundaries, same-session re-anchor preservation, noise filtering, distinct keyed decisions and answer modes, cap disclosure, current PR precedence, meaningful in-flight names, decision retention, missing-ledger tolerance, and absence of read side effects.
The metadata fixture deliberately has no endpoint, so no worker or shared session is contacted.
A fixture with no endpoint publishes an unknown worker state rather than establishing that a real worker is alive; worker liveness itself is unchanged and outside this change's scope.
The driver always removes its disposable home, including on failure.
Remove the empty `.test-tmp` directory after testing.

The numbered JSON artifacts are the actual production CLI response at each scenario step.
`live-cli-transcript.json` preserves command arguments, exit codes, stdout, and stderr.
`attention-regression.log` records the separate targeted behavior regression script, which includes fake external tools and is supplementary rather than live-product evidence.
No screenshot is applicable: this change exposes machine-consumed CLI JSON and adds no rendered UI.

No primary session, Herdr lifecycle, shared fleet data, external PR, credential, or global configuration was modified.
