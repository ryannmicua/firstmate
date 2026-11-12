# GitHub identity and inbox local validation

Run from the gate worktree:

`python3 ~/.no-mistakes/evidence/01M76SRAYFNN4HYKJKEQJVSMDM/live-validation.py`

Requires Python 3, Bash, curl, jq, Git, gh, and OpenSSL on PATH.
The driver starts a localhost GitHub API emulator and creates synthetic configuration under `.validation-live/product`.
It runs actual identity, poll, and inbox scripts with real curl, Git, gh, and OpenSSL processes, then removes its home and stops its server.
Only invented tokens and isolated owner credentials are used; no operator data or real GitHub service is accessed.

The independent oracle is the supplied intent: workers use bot credentials and attribution, owner credentials remain usable outside the worker environment, owner requests become instructions, and others explicitly say not to act.
App token requests must name the single repository and refresh after expiry.
Guards must reject shared secret files, insufficient permissions, embedded authentication, and owner netrc credentials.
Intake must use verified GraphQL text, deduplicate replay, preserve its cursor after HTTP failure, process commits without issue-event endpoints, ignore deleted latest-comment URLs, and leave no recreated records after disarm.

Evidence: `live-transcript.log` contains commands, actual output and exit statuses; `inbox-output.txt` is the product inbox listing; `local-api-requests.json` records HTTP requests with synthetic credentials and redacted JWTs; `live-results.json` records the five results.

Supplemental focused regressions also exited 0:

- `TMPDIR="$PWD/.validation-live/tmp" bash tests/fm-gh-identity.test.sh`
- `TMPDIR="$PWD/.validation-live/tmp" bash tests/fm-gh-bot-check.test.sh`

These regressions substitute external tools; live results come from the separate real-process localhost run.
No browser or GUI surface changed; reviewer-visible evidence is CLI output.
