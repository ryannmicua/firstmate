### GitHub bot notification intake

Last tested: 2026-11-19 at c0dc08cccd52f422085ef20b564d9aad6f87f373.

From the repository root, create .test-local and execute the accompanying
live_github.py with Python 3, curl and jq on PATH. Its evidence destination is
explicitly pinned at the top; update it for a later run. Remove .test-local after.
The driver removes its disposable home and stops/joins its localhost HTTP server
in a finally block. All accounts, tokens and GitHub repository records are synthetic.
No GitHub service or operator data is accessed. Real Firstmate CLI commands and
real curl requests drive the product; only the external GitHub API is emulated.
The independent oracle is the accepted owner/stranger trust, deduplication,
assignment, self-exclusion and permission contract. Wrong trust, duplicate notes,
missing empty approvals or accepting non-admin credentials for --admin fail it.

Evidence includes actual CLI output, persisted inbox notes and HTTP requests.
Authorization is recorded only as a boolean matching a synthetic credential.
The emitted approval note is an intentional generated interface; it does not prove
supervisor interpretation, actual migration labeling or real GitHub merge behavior.

Focused existing regression selectors (all completed exit 0):
- fm-gh-bot-check: test_assigned_thread_captures_activity_without_mentions,
  test_approval_names_a_configured_migration_label,
  test_unassigned_thread_ignores_unmentioned_activity,
  test_item_identity_survives_mention_edits,
  test_bot_mentions_are_excluded_across_item_types,
  test_assign_action, test_can_merge_and_reply_actions,
  test_gh_action_keeps_token_off_argv.
- fm-pr-merge: test_github_merge_identity_prefers_the_bot.
- fm-pr-check-security: test_ready_pull_request_assigns_the_bot.
- fm-dod-lib: test_pr_based_dod_draft_check_uses_gh_axi.

These were executed using disposable tests/.local-*.sh copies with other bare
top-level test calls removed. External-boundary stubs mean these regressions are
not live merge evidence. An initial merge-selector copy retained earlier
interspersed calls and was stopped (exit 143) with its descendants; the corrected
focused selector completed exit 0. No complete repository suite, lint, formatter,
or static analysis ran. All disposable files were removed after checks.

Full worker-opening and supervisor approval-to-merge validation requires an
authorized disposable GitHub repository and distinct owner/bot credentials.
This phase prohibits initiating delivery phases or accessing operator data.
The localhost workaround exercises CLI interfaces, but cannot establish model
interpretation or tenant behavior. This is the previously accepted validation
limitation, not a new finding. No rendered UI changed; CLI/inbox records provide
the user-visible evidence, so no screenshot was required.
