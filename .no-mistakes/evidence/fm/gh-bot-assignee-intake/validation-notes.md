# Local validation

Run the retained live-intake.py from the gate worktree using its absolute path.
It mints a disposable marked home within the worktree, starts a localhost HTTP API with synthetic inputs, and executes the real bot poll, real curl, and real inbox.
It stops and joins the server and removes its home before returning.
All six executable local scenarios passed.
The oracle is the supplied owner intent: trust owner activity, mark visitors informational, capture blank reviews, deduplicate mention edits, and exclude bot activity.
The initial driver counted .md records instead of .note records; the corrected run passed without product changes.
The initial setup transcript is retained separately.

## Delivered approval instruction gap

The real poll delivered this conditional instruction in the owner approval inbox note:

> If the PR contains a data migration and the project gates migrations with a label (for example migration-approved in rms-cares), firstmate adds that label before merging

This is generated public output read through fm-inbox.sh drain, rather than a source-text assertion.
Criterion 3 and the accepted round-1 R2 decision require the migration label for database changes.
A project without a separate migration gate can follow this delivered instruction while omitting the required label.
The same conditional contract appears in docs/configuration.md.
This proves a delivered-contract gap; it does not claim an actual database PR was merged without a label.
Repair the emitted instruction and documentation to require the migration label for database changes independently of a separate project gate.

## Supplemental checks and limits

Existing fm-gh-bot-check and fm-dod-lib test files exited zero with TMPDIR inside the worktree.
Temporary runners selected these existing regression functions and exited zero:
- fm-pr-merge: test_github_merge_identity_prefers_the_bot
- fm-pr-merge: test_github_red_checks_refuse_and_allow_red_waives_named
- fm-pr-merge: test_required_check_that_never_reported_refuses
- fm-pr-check-security: test_ready_pull_request_assigns_the_bot

Those checks use fake forge commands and are not live merge or worker-opening proof.
Temporary runners and scratch data were removed.
The generated worker-delivery-handoff.md shows the emitted PR-opening instructions, without proving a worker follows them.
No real worker opened a PR, and no live firstmate completed approval, cancellation, migration labelling, merge, and reply.
The localhost API and deterministic checks establish intake and command contracts but cannot establish those agent-mediated outcomes.
Complete proof needs a disposable GitHub repository, separate bot and owner credentials, authority to mutate it, and an outer-executor-driven worker opening/CI handoff.
This phase forbids controlling another pipeline and using operator services or credentials; those external actions were not attempted.
There is no changed rendered UI; screenshots do not apply to these CLI and inbox surfaces.
