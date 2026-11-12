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

## Effective transport and incremental discovery

Verified 2026-11-12: the focused identity script passed thirteen cases and the focused inbox script passed nine cases using the commands above.
Effective-origin tests cover SSH ports, HTTPS ports, a different repository, another host, file push rewrites, and fetch rewrites; each unsupported configuration refuses before launch and identifies its remote setting.
Credential-free HTTPS and both supported SSH spellings resolve successfully through the worker's shared rewrite entries.
Actual worker fetch and push refuse SSH transport after a remote is changed to the port-bearing SSH form; a fake SSH command prevents network access if enforcement regresses.
The spawn fixture routes network operations to a local bare repository without changing URL resolution, including remote-tracking refs and default-branch discovery.
The incremental-discovery regression checks persisted owner notes, HTTP acknowledgement, and call ordering before a second-page HTTP 500; read notifications are skipped.
Discovery includes read records so acknowledgements do not shrink the list during pagination, while only unread supported notifications consume the handling allowance.

## Pagination and inherited HTTP authentication

Verified 2026-11-12 with the two focused commands above: fourteen identity cases and nine inbox cases passed.
Notification fixtures now use the supported 50-record discovery page size, including a full first page followed by an owner mention and a later-page failure after saved progress.
Per-thread comment, review, and event pagination continues to use 100-record pages.
Git's public URL-match configuration interface resolves empty extraHeader lists for github.com when generic, host, repository-path, default-port, and inherited environment headers are present.
The environment generator reads matching header key names only and does not copy their values into its output; unrelated-host configuration remains effective.
The worker-wide protocol allowlist has been removed, superseding the earlier worker SSH-refusal evidence in this record.
The origin-validation checks still reject unsupported effective GitHub fetch and push URLs; a real local clone under the worker environment now succeeds and reproduces the source HEAD.
