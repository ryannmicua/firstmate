# AgentMail blocked-mail live verification

Last tested: 2026-11-19.

The executable intake and inbox CLIs run unchanged with real curl against a disposable localhost HTTP service.
Only AgentMail is emulated; this proves local intake behavior with synthetic messages, not a production mailbox or receive-block-list configuration.
The independent oracle is the author's requirement that blocked mail produce no inbox note or wake, plus the documented retained trust classification for allowed mail.

## Repeat

1. From the repository root, create `.agentmail-live/` and copy the adjacent `drive.py` there.
2. Run `python3 .agentmail-live/drive.py EVIDENCE_DIRECTORY` with an absolute evidence directory that already exists.
3. Read `live-transcript.txt` when capturing stdout there, and inspect the generated JSON records.
4. Remove `.agentmail-live/drive.py` and its empty directory afterward.

The driver creates homes below `.agentmail-live`, uses synthetic owner and GitHub sender addresses, and binds its HTTP server only to localhost on an allocated port.
It clears inherited `FM_*` overrides and supplies an invented key.
It never sends email, calls production AgentMail, starts a primary agent, or touches an operator home.
Its finally block stops and joins the server and removes disposable homes and baseline links.
No production-data actions are needed or authorized by this recipe.

## Scenarios and evidence

- `blocked-first-poll.json` and `blocked-repeat-poll.json`: GitHub sender, authenticated owner, and pending-scan blocked messages produce no notes, no wake rows, and no body fetches; seen labels persist and repeated polling remains quiet.
- `base-regression.json`: the base intake, executed with the same real dependencies, produces a note and wake from the identical blocked GitHub message.
- `mixed-pages.json` and `mixed-repeat-poll.json`: three listing pages retain allowed owner, spam, unauthenticated, and stranger mail; four notes and four wake rows appear exactly once, with their expected trust classification.
- `seen-label-failure.json` and `seen-label-recovered.json`: HTTP 503 yields a nonzero poll and specific diagnostic without a note or wake; the next successful poll persists the seen label quietly.

An initial baseline fixture attempt created the note but could not announce it because its temporary script root lacked `bin/`.
The fixture layout was corrected and the entire driver reran successfully with exit 0.
The retained JSON and final transcript are from that successful run.
No repository suite, linter, formatter, remote validation, or pipeline-control command ran.
There is no rendered UI in this CLI-only change; evidence consists of actual CLI results, HTTP exchanges, mailbox labels, inbox notes, and wake-queue records.
