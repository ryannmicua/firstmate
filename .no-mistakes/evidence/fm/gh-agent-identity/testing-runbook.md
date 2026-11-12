# GitHub writing identity and bot intake: local live validation

Last tested: 2026-11-12. Target: 9b5e8f8bdd952b8c4dd23455801c1da9ea7037ed.

## Scope and evidence

The real identity, bot-check and inbox scripts, system Git, curl, OpenSSL and gh ran against an in-process localhost HTTP API and HTTPS CONNECT proxy with synthetic credentials. Git smart HTTP requests ran the real `git http-backend` over a disposable bare repository. This proves local execution; it does not validate an actual GitHub installation, bot account, production notification delivery, or a launched model worker.

`live-product-transcript.txt` records commands and actual product output. `persisted-inbox-notes.txt` contains the 14 resulting public inbox-note records. `local-api-requests.json` records methods, paths, synthetic actors and request bodies, with authorization values omitted. `live-scenarios.json` records the six final results.

## Repeat

From the gate worktree, create `.local-validation/tmp`, then execute `python3 <evidence-directory>/live-product-driver.py`. The driver requires Python 3, Bash, Git, curl, OpenSSL and gh on PATH. It creates marked lab homes underneath `.local-validation`, generates a disposable TLS certificate and App key, starts a localhost API, and redirects only its child clients through that API/proxy. All fixtures and credentials are synthetic. It stops and awaits its server, terminates its unrelated-process sentinel, and disarms its owned bot poll before returning. Remove `.local-validation` after preserving evidence.

Run the focused baseline behavior checks separately:

- `TMPDIR="$PWD/.local-validation/tmp" bash tests/fm-gh-identity.test.sh`
- `TMPDIR="$PWD/.local-validation/tmp" bash tests/fm-gh-bot-check.test.sh`

Both exited 0 in this run. These existing checks use fake external tools and are supplemental, not the live scenario evidence.

## Expected behaviors

1. A token worker prepares successfully, commits and pushes/fetches as the bot, and uses the bot in real gh. An outside gh invocation still uses a synthetic owner credential and the outside Git config remains byte-identical.
2. An App worker signs a JWT verified by OpenSSL, mints only for widget, pushes as the App, reuses its token and refreshes near expiry. An uncovered installation refuses without publishing a worker profile.
3. Publicly readable token files, inaccessible repositories, embedded remote credentials and GitHub netrc entries refuse, without falling back to owner authentication.
4. Owner mentions and assignments become instructions; outsiders, collaborator edits and unverifiable provenance become do-not-act notes. Verified GraphQL text replaces stale REST text. Issue/PR bodies, issue comments, review comments, submitted reviews and commit comments are exercised. Pending reviews and a deleted latest-comment URL are excluded.
5. More than one notification page is consumed. Replaying the initial window produces no duplicate notes or reactions. A second-page HTTP 503 preserves the cursor, then recovery completes.
6. Arm produces the trusted shim; check replaces a stale lock pointing at an unrelated live PID and returns while retrieval is delayed. Disarm stops its owned process group, leaves that unrelated PID alive and does not recreate state after the delayed-response window.

## Gotcha resolved during this run

`check` launches asynchronously. If a stale symlink already exists, the command can return before its child replaces it. The initial driver sampled that stale symlink too soon. The corrected driver waits up to three seconds for replacement before assessing ownership; the final rerun passed. No product fix was required.

## Safety and cleanup

Never point this driver at operator homes or real GitHub credentials. All pushes go through the local TLS proxy into the local bare repository. No GitHub writes occur. No fleet runtime or harness session is launched. No UI surface changed, so CLI transcripts and persisted records are the reviewer evidence. Final disposable fixture cleanup left the source worktree unchanged.
