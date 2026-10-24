# Fleet activity ledger

The fleet activity ledger is an opt-in, append-only file that outside tools can read to follow what a firstmate home is doing: which tasks were dispatched, what their workers reported, when a PR became ready for review, when their work merged, when they were cleaned up, and when a decision was put to the captain or answered.
It is the stable, documented hook for firstmate status; this page is its contract.

## Turning it on and off

Create the presence flag `config/fleet-ledger` in a firstmate home to turn the ledger on, and delete it to turn the ledger off.
The flag is local, gitignored, per home, and not inherited by second mate homes, so each home that should publish a ledger needs its own flag.
While the flag is absent, each producer performs one file-existence test and nothing else: no process starts and nothing is written.

## The file

The ledger is `state/fleet-ledger.jsonl` in that home, in JSON Lines format: one JSON object per line, each ending in a newline.
Records are only ever appended, in the order they are written.

Every record carries these members:

| Member  | Meaning                                                   |
| ------- | --------------------------------------------------------- |
| `v`     | Record format version, currently `1`                      |
| `ts`    | Unix time in seconds when the record was written          |
| `event` | One of the event names below                              |
| `task`  | The firstmate task id the record is about                 |

Readers must ignore members and events they do not recognize, so later versions can add them without breaking existing readers.

## Events

| Event              | Extra members                                  | Written when |
| ------------------ | ---------------------------------------------- | ------------ |
| `task.dispatched`  | `kind`, `project`, `harness`, `model`          | A new worker or second mate is launched. A relaunch of an existing task is not recorded. |
| `task.status`      | `state`, `key`, `text`                         | A complete, nonblank line in the task's status log is captured. |
| `task.pr_ready`    | `pr`                                           | Firstmate records the task's PR as ready for review. |
| `task.merged`      | `via` (`"pr"` or `"local"`), plus `pr` when `via` is `"pr"` | The task's PR merge is recorded, or its local-only branch landed. |
| `task.cleaned_up`  | none                                           | The task's worker and local copy were removed. |
| `captain.held`     | none                                           | A task is held for the captain with no deferral date. |
| `captain.deferred` | `until`                                        | A task is held for the captain with a deferral date. |
| `captain.answered` | `mode` (`"done"`, `"release"`, or `"reconciled"`) | A captain-held task's call was answered, released, or closed as moot. |

`task.dispatched` members: `kind` is `ship`, `scout`, or `secondmate`; `project` is the project directory name, or `null` for a remote second mate; `harness` names the agent tool; `model` is the requested model, or `null` for the tool's default.

`task.pr_ready` members: `pr` is the PR's full URL.
It is written each time firstmate records a PR for the task, so registering a replacement PR, or the same PR again, writes another record; recording the PR again as part of merging it writes none.

`task.status` members: `state` is the status line's leading word, such as `working`, `needs-decision`, `blocked`, `paused`, `done`, `failed`, or `resolved`, or `null` when the line has none.
`key` is the line's `[key=...]` decision key, or `null`.
`text` is the status line after its first colon, verbatim, capped at 2000 characters; if the line has no colon, it is the whole line.

`captain.held` and `captain.deferred` are the two spellings of one hold: a new hold or a change to its reason or deferral date writes exactly one of them.
`captain.deferred` has `until`, the `YYYY-MM-DD` date the captain deferred the call to.
`captain.answered` has `mode`: `done` when the captain's answer closed the task, `release` when the answer released the hold and kept the task, and `reconciled` when the call closed as moot on evidence rather than an answer.
`task` is the held task's id.
These events come from `bin/fm-captain-hold.sh`, which writes them as it publishes the hold or answer, and an unchanged re-hold writes no new event.
Each task's newest `captain.*` event describes its latest recorded hold or answer transition, not its complete current state: holds can predate recording or change while recording is off.
For the current open calls, use the [attention feed](#open-decisions-for-outside-readers), which reads the current backlog and status decisions rather than inferring membership from ledger history.

Example:

```json
{"v":1,"ts":1790132857,"event":"task.dispatched","task":"fix-login","kind":"ship","project":"webapp","harness":"claude","model":null}
{"v":1,"ts":1790132870,"event":"task.status","task":"fix-login","state":"working","key":null,"text":" bug reproduced"}
{"v":1,"ts":1790133400,"event":"task.status","task":"fix-login","state":"done","key":null,"text":" PR https://github.com/acme/webapp/pull/7 checks green"}
{"v":1,"ts":1790133410,"event":"task.pr_ready","task":"fix-login","pr":"https://github.com/acme/webapp/pull/7"}
{"v":1,"ts":1790133900,"event":"task.merged","task":"fix-login","via":"pr","pr":"https://github.com/acme/webapp/pull/7"}
{"v":1,"ts":1790133960,"event":"task.cleaned_up","task":"fix-login"}
{"v":1,"ts":1790134000,"event":"captain.held","task":"pick-auth-flow"}
{"v":1,"ts":1790134100,"event":"captain.deferred","task":"rename-api","until":"2026-12-01"}
{"v":1,"ts":1790134200,"event":"captain.answered","task":"pick-auth-flow","mode":"done"}
```

## Open decisions for outside readers

`bin/fm-attention.sh --json` prints the decisions waiting on the captain, this session's activity, and the in-flight items, as one JSON object with schema `fm-attention.v1`.
It is read-only: it folds the home's local fleet snapshot and this ledger on every call and stores no separate board.
The local projection reads holds through the configured backlog adapter and skips secondmate summary collection and its cache.
It works without a ledger, in which case each row's `last_touched_at` equals its `opened_at` and `session_activity` is empty.
Turning recording off leaves existing ledger history available to this read.

The object has `schema`, `generated` (UTC, ISO 8601, second precision), `session`, `session_activity`, `session_activity_total`, `session_activity_truncated`, `in_flight`, and `open_decisions`.
Readers must ignore members they do not recognize, so later versions can add members without changing the schema name.
All times are UTC, ISO 8601, second precision.

### Session activity

`session` has `started_at` and `source`, which identify the session boundary or an explicitly labeled fallback window:

| `source`           | `started_at` is                                                                                     |
| ------------------ | --------------------------------------------------------------------------------------------------- |
| `session_lock`     | when the session lock was acquired, the modification time of `state/.lock` |
| `session_identity` | when the session lock last recorded a new session identity, such as a `/clear`, the modification time of `state/.lock-session` |
| `fallback_24h`  | 24 hours before the read, when neither session boundary is available; this is a rolling window, not a session                                               |

When both records exist, the later one wins.

`session_activity` lists this ledger's events from `started_at` on, newest first, at most 100 items.
`session_activity_total` counts distinct eligible items before the cap, and `session_activity_truncated` is true when the cap omits items.
Each item has `at`, `task`, `event` (the ledger event name), `state`, `key`, `mode`, `line`, `detail`, and `pr`.
`key` and `mode` preserve the recorded decision key and answer mode, or are `null` when absent.
`line` is one plain sentence built from the task's backlog title, or its task id when the backlog no longer has it:

| Event                                   | `line`                                    |
| --------------------------------------- | ----------------------------------------- |
| `task.dispatched`                       | `Started: <title>`                        |
| `task.status` with `state` `needs-decision` | `Needs your decision: <title>`        |
| `task.status` with `state` `failed`     | `Failed: <title>`                         |
| `task.status` with `state` `resolved`   | `Resolved: <title>`                       |
| `task.status` with `state` `blocked`    | `Blocked: <title>`                        |
| `task.status` with `state` `done`       | `Worker finished: <title>`                |
| `task.pr_ready`                         | `PR ready: <title>`                       |
| `task.merged`                           | `Merged: <title>`, or `Landed locally: <title>` for a local-only landing |
| `task.cleaned_up`                       | `Cleaned up: <title>`                     |
| `captain.held`                          | `Waiting on you: <title>`                 |
| `captain.deferred`                      | `Deferred to <until>: <title>`            |
| `captain.answered`                      | `You answered: <title>`, `You answered and kept it open: <title>` for `release`, or `Closed as moot: <title>` for `reconciled` |

Other status lines, such as `working` or `paused`, and events this list does not name are left out.
Only identical ledger records collapse, including their timestamp, task, event, state, decision key, answer mode, and payload; distinct recorded transitions remain separate.
`state` is the status line's state for a `task.status` item and `null` otherwise.
`detail` is the status line's text, trimmed to 160 characters, for a `task.status` item and `null` otherwise.
`pr` is the task's current local PR URL (metadata first, then status-log discovery), else the event's own PR URL, else the newest PR URL this ledger records for the task, else the backlog item's PR URL, else `null`.
The list reports only what the ledger recorded, so its [limits](#limits) apply: status lines already in a log when recording was turned on appear at the time they were recorded, not when they were written.

### In-flight items

`in_flight` lists the backlog's in-flight items in backlog order, the same items `bin/fm-inbox.sh status` prints as text.
Each item has `task`, `title`, `repo`, `kind`, `worker`, `last_event`, and `pr`.
`worker` is the fleet snapshot's current state for the task's worker, such as `working`, `done`, or `unknown`, or `null` when no worker is recorded for it.
`last_event` is the task's newest status line, trimmed to 160 characters, or `null`; like any status line, it is history rather than current state.
`pr` follows the same order as in `session_activity`.

### Open decisions

Each row has `task`, `home` (`"main"`), `title`, `kind`, `reason`, `bucket`, `opened_at`, `opened_precision`, and `last_touched_at`.
A `kind` of `captain_hold` is a backlog task held for the captain.
Its `opened_at` is the hold-set stamp, and its `bucket` is the fleet snapshot's `hold_bucket` (`live`, `dated`, `blocked`, or `aged`) unchanged.
A date-only hold-set stamp uses `opened_precision` of `day`.
A legacy hold with no stamp falls back to the backlog `since` date, with `opened_precision` of `day` instead of `second`.
A `kind` of `keyed` is a keyed status decision a task still holds open, such as a second mate's escalated call; it adds `key`, has a `null` `bucket`, and takes `opened_at` from the opening line's `[at=<epoch>]` stamp, or `null` when the line has none.
`opened_precision` is `second` for a timestamp, `day` for a date, or `null` when no opening time is known.
`last_touched_at` is the newest of `opened_at` and this ledger's `captain.held` or `captain.deferred` events for a hold.
For a keyed decision, `last_touched_at` equals `opened_at`; ledger capture time does not change source emission ordering.
Rows sort newest first by `last_touched_at`, and rows with no time sort last.
The read covers the home it runs in, and not the second mate homes it supervises, except for the keyed decisions those mates escalate into this home's status logs.

## Limits

- A worker using the current status command in its instructions records its line immediately after appending it, while the ledger is enabled.
  The supervision monitor's regular poll is the backstop: it records any line the immediate write missed, and does not record again a line that write already recorded.
  These lines still trail the status log by up to one poll interval, or until the monitor next runs when none is running:
  - lines firstmate itself writes to a task's status log, such as a recorded answer, a failed launch, a relayed pending reply, or a second mate's report line;
  - lines from workers whose instructions predate this, or that append without running the instruction's full command;
  - lines a remote second mate reports, which reach this home through firstmate's relay;
  - lines written while the immediate record fails, for example when the ledger file cannot be written.
  Recording `task.pr_ready`, `task.merged`, or `task.cleaned_up` first records that task's pending status lines.
- Captured status lines are delivered at least once unless a write fails or a crash loses unflushed records: an interrupted capture can repeat records, so a reader that must not double-count should tolerate duplicates.
- A status record can appear just before its task's `task.dispatched` record when the worker writes a status line in the moment between its launch and that record.
- When a home turns the ledger on, status lines already in a live task's log are recorded on that task's next capture (which may be a worker status command, PR registration, merge, cleanup, or monitor poll); tasks dispatched or cleaned up while the flag was absent have no record of that.
- There is no sequence number and no gap detection.
- Writes are plain appends with no forced flush to disk, so a machine crash can lose the newest records.
- The file is never rotated and grows until truncated.
  To truncate it, stop reading, then empty it with `: > state/fleet-ledger.jsonl`; later records append to the empty file.
- The ledger copies status text verbatim from the home's `state/` directory and adds no scrubbing, so give its readers exactly the trust you give `state/`.

## Not included

These are possible follow-ups, deliberately left out of this version:

- session start, away-mode, and quiet-mode events;
- relaunch events;
- whether a worker is currently working or idle, and when a turn ends; subscribe to the Herdr runtime's own `pane.agent_status_changed` events for that ([Push events and polling fallback](herdr-backend.md#push-events-and-polling-fallback));
- sequence numbers and gap detection;
- rotation and continuity across rotated files;
- backfill or replay of events from before the ledger was turned on;
- secret scrubbing beyond what status lines already contain, and privacy guarantees stronger than those of `state/`.

`bin/fm-fleet-ledger.sh`'s header owns the writer mechanics and lists every producer.
