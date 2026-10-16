# Output-guidance live validation

Last tested: 2026-10-16.

Run the targeted CLI behavior checks with `bash tests/fm-prose-lint.test.sh`.
For real consumer coverage, put a workspace-local Vale binary on PATH, set FM_PROSE_LINT_CACHE and TMPDIR to disposable workspace directories, then run `bin/fm-prose-lint.sh --sync`.
Vale 3.24.0 was used here; no global installation or configuration changed.

1. Generate ship and scout briefs with `bin/fm-brief.sh <id> sample --mode no-mistakes` and `bin/fm-brief.sh <id> sample --scout`, using FM_HOME inside the workspace and clearing inherited FM_* path overrides.
2. Inspect the generated public instructions for the conventions section and runnable paths. Generate a secondmate charter with `--secondmate --no-projects` and verify the worker section is absent.
3. Submit the inputs in real-vale-transcript.txt through stdin. Verify the 25-word lead is accepted, the 26-word lead warns, and each of the five configured rules produces a finding. All style findings must exit zero.
4. Submit the Markdown/status input in status-file-transcript.txt as a .txt file. Verify heading/prefix handling, original file label, and line/column reporting.
5. Remove Vale from PATH, use an empty package cache, and damage a copied cached rule in turn. Verify the distinct diagnostics in advisory-failure-transcript.txt and continued lead checking with exit zero. Restore the disposable rule after this test.
6. Invoke no arguments, an unknown option, and a missing path. These usage errors must exit two.

All writes stay in a disposable workspace subtree except published evidence. No fleet lifecycle, model login, production data, or shared service is needed.
Remove the disposable home, binary, download, package cache, and temporary files afterward.

The static worker guidance was read against the supplied writing profile, notation map, checklist, and advisory configuration. This validates instruction adoption, not model compliance in future generated reports. No rendered UI changed, so CLI transcripts and generated Markdown are the product evidence.
