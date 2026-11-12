# PR delivery instruction verification

Last tested: 2026-11-12.

Public interface: `bash bin/fm-brief.sh <id> invented-project --mode <mode> [--forge gerrit]`.
Run with `FM_HOME` pointing at a disposable directory inside the current worktree and with inherited FM path overrides removed.
No project checkout, remote publication, credentials, fleet session, or model invocation is required.
Remove the disposable home after retaining generated briefs.

The independent oracle is the supplied author intent: ordered merge line, Why, What changed, Screens, Verified, Risk and recovery; screenshots restricted to invented data; public-repository asks summarized rather than quoted.
The latest recorded human decision leaves the footer requirement in place; this verification does not challenge it.

Executed five real scaffold CLI calls, each exiting zero.
Manually inspected the emitted no-mistakes definition of done and checked the generated instruction contracts for both PR modes.
Both include the ordered layout, final-diff read-back, invented-only screenshot rule, and public-summary rule.
The no-mistakes output additionally requires `--no-publish-intent` before starting a public-repository run and preservation of generated marker comments or appendices when editing the PR body.
Direct-PR output does not prescribe that pipeline flag.
Adversarial boundary checks generated local-only and both Gerrit modes: all omit the PR body shape.
These checks reject a missing/reordered layout, a broader demo-data allowance, a missing privacy instruction, or PR-specific guidance leaking into non-PR deliveries.

Also executed `bash tests/fm-dod-lib.test.sh`; actual exit status was zero.
That deterministic regression is supplemental, not evidence of model compliance.

Scope: the product surface exercised is generation of the worker's delivery instructions.
No worker was asked to publish a PR, no no-mistakes run was initiated, and no actual screenshot upload or public-repository privacy behavior was exercised.
The change introduces instructions rather than enforcement of those downstream actions.
No UI is changed; generated Markdown is the reviewer-visible product output, so no screenshot was captured.
No background processes were launched by the manual scenarios; the regression command was awaited to completion.
The disposable scenario home was removed and `git status --short` remained empty.
