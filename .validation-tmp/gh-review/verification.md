# GitHub identity and bot intake verification

Verified 2026-11-12 through executable interfaces with fake GitHub responses and invented credentials.

Run from the worktree root:

```bash
mkdir -p .validation-tmp/gh-review
TMPDIR="$PWD/.validation-tmp/gh-review" bash tests/fm-gh-identity.test.sh
TMPDIR="$PWD/.validation-tmp/gh-review" bash tests/fm-gh-bot-check.test.sh
```

Both scripts passed: nine identity cases and six intake cases.
The identity cases exercise real git credential consumption, including refusal before a later owner helper can answer, and fake worker launch boundaries.
The intake cases use persisted inbox notes and recorded HTTP calls as observable contracts.
The independent oracles are configured-identity isolation, owner-only instruction authority, complete retrieval before acknowledgement, and supported-reason-only consumption.
Regressions rejected include an old App token after configuration changes, read-only worker preparation, lost subject or later-page mentions, stale owner attribution, and acknowledgement after partial retrieval.
No real GitHub account, credential, or network mutation is needed.
The test harness removes its fixtures on exit; this evidence directory may remain private.

## Additional review coverage

Verified 2026-11-12 with the same two commands above: ten identity cases and eight inbox cases passed.
The new spawn case checks fresh ship/scout spawns and relaunches with configured identities against a fake paseo-agent runtime, asserting refusal, no runtime calls, and unchanged branches and worktrees.
Notification discovery checks a supported record after twenty unsupported records and another on the next page, while unsupported records remain unread.
Submitted review summaries check a later-page owner mention after an ordinary later comment, failure before any notes or acknowledgement on an unavailable page, exclusion of pending reviews, and aggregation of a response larger than a typical single-argument limit.
The initial discovery fixture omitted jq's null-input option; the corrected fixture and the entire inbox script passed on rerun.

## Embedded remote credentials

Verified 2026-11-12 with `TMPDIR="$PWD/.validation-tmp/gh-review" bash tests/fm-gh-identity.test.sh`: all twelve cases passed.
The spawn regression exercises eight credential-bearing remote configurations through fm-spawn, including multiple push URLs and insteadOf/pushInsteadOf rewrites, and checks refusal, no launch, and no invented-token disclosure.
The worker regression sends supplied credentials directly to the helper and exercises actual git fetch and push with the emitted worker environment.
Both transport operations refuse plaintext credentials before invoking the fake HTTPS transport.
The fake transport prevents real network access if the guard regresses.
The oracle is the configured-identity isolation requirement: embedded owner credentials cannot bypass the bot identity.
