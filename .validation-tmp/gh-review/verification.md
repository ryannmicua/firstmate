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
