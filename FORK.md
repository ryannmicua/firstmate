# About this fork

This repository is a fork of [`kunchenguid/firstmate`](https://github.com/kunchenguid/firstmate).
This document records what this fork carries over upstream, which add-ons attach to it, and how changes move between the two.
It holds mechanism only and contains no site-specific or private data.

## Policy

Every change goes to the first of these that fits:

1. **Upstream first.**
   Generic firstmate behavior is proposed to upstream as a small, opt-in pull request.
   Before building anything, check whether upstream already has it or is building it, so the fork does not duplicate work upstream will land.
2. **Add-ons second.**
   Personal or site-specific behavior, and anything reachable from an existing extension point, lives in its own repository and attaches to firstmate without editing it.
3. **A thin fork last.**
   The fork carries only what upstream has declined or has not merged yet and that cannot be an add-on.
   Each carried change is recorded in the ledger below with the condition that retires it.

The aim is a fork that stays close to upstream, syncs cheaply, and shrinks as upstream absorbs its changes.

## Carry ledger

One row per change the fork carries over upstream.
Remove a row when its drop condition is met, and note the removal in the sync merge message.

| Change | Files | Why it is carried | Upstream | Drop when |
| --- | --- | --- | --- | --- |
| Paseo runtime backend (opt-in, explicit-only) | `bin/backends/paseo.sh`, dispatch arms in `bin/fm-backend.sh`, `bin/fm-spawn.sh`, `bin/fm-control.sh`, `bin/fm-control-lib.sh`, `bin/fm-teardown.sh`, `docs/paseo-backend.md`, `tests/fm-backend-paseo.test.sh`, `tests/fm-spawn-paseo-env.test.sh` | The runtime backend list is hard-coded in core, so a backend cannot be an add-on, and upstream has not merged a Paseo backend. | Open upstream pull requests [#4728](https://github.com/kunchenguid/firstmate/pull/4728) and [#2187](https://github.com/kunchenguid/firstmate/pull/2187) | An upstream Paseo backend merges; then keep only the pieces upstream lacks and propose those, or drop them. |
| Paseo project registration helper | `bin/fm-paseo-project.sh`, `tests/fm-paseo-project.test.sh`, Paseo registration sections in [the `project-management` skill](.agents/skills/project-management/SKILL.md#automatic-paseo-registration) | Registers a firstmate project in Paseo so the backend can match its checkout; depends on the carried backend. | None | The Paseo backend row is dropped, or upstream's backend covers project registration. |

Carry a change that is pending upstream as the exact upstream pull request commit, not a rewritten variant.
Preserving commit identity helps Git recognize shared history when upstream merges it; squash or rebase merges and overlapping changes can still require conflict resolution.

## Add-on index

Each add-on is its own repository, installed and upgraded separately from any firstmate home.
Neither add-on edits this repository.

| Add-on | What it does | How it attaches | Install |
| --- | --- | --- | --- |
| [Quarterdeck](https://github.com/ryannmicua/quarterdeck) | Renders one local review page from homes' backlogs, reports, and `bin/fm-bearings-snapshot.sh --json`. | Standalone consumer of durable records and machine outputs; serving is read-only by default, with optional report review marks. | See its README Quick Start. |
| [firstmate-claude-artifacts](https://github.com/ryannmicua/firstmate-claude-artifacts) | Lets Claude artifacts and Claude Docs serve as a review surface: a comment-check adapter plus a watcher skill for workers. | Trusted external process-event adapter bound through `bin/fm-extension.sh` into `config/extensions.d/` ([`docs/extension-bindings.md`](docs/extension-bindings.md)), plus a user-level skill outside the repository. | See its README and tutorial. |

Extension points that exist today, in order of preference for new add-ons:

- A read-only consumer of `data/`, `state/`, and machine outputs such as `bin/fm-bearings-snapshot.sh --json`.
- A trusted external process-event adapter bound under `config/extensions.d/`; [`docs/extension-bindings.md`](docs/extension-bindings.md) owns the contract and states what it does not cover.
- Home brief additions through `config/brief-include.md` ([`docs/configuration.md`](docs/configuration.md#home-brief-include-configbrief-includemd) owns scope and constraints).
- User-level skills and harness settings, which live outside the repository.

There is no executable out-of-tree hook into wake triage, brief generation, runtime backend dispatch, or the validation pipeline.
A change that needs one is an upstream proposal, or a ledger row here while it is pending.

## Syncing from upstream

Sync by merge, not rebase, about weekly or whenever an upstream fix is wanted.
Rebasing would rewrite the published default branch that homes fast-forward to.

1. Keep an `upstream` remote on the checkout: `git remote add upstream https://github.com/kunchenguid/firstmate`, then `git fetch upstream`.
2. As an ordinary ship task, branch from the fork's default branch and run `git merge upstream/main`.
3. Resolve conflicts, preferring upstream's version of shared files and re-applying carried changes on top.
4. Drop any carried patch that upstream now duplicates, remove its ledger row, and name it in the merge message.
5. Validate through the normal delivery path for this repository.
6. Open the pull request against the fork, never against upstream, and confirm the base repository before pushing; the captain merges.
7. After the merge, update running homes by fast-forward with `/updatefirstmate`.

## Proposing a change upstream

Upstream's `CONTRIBUTING.md` owns the contribution rules; this is how the fork applies them.

1. Search first: `git fetch upstream`, then search upstream's log and pull requests for the topic; contribute to an existing thread instead of building a parallel version.
2. Use a separate checkout whose `origin` is upstream, initialized for the validation pipeline with the fork as the push fork, as upstream's `CONTRIBUTING.md` describes.
3. Branch from `upstream/main`, never from the fork's default branch, so the pull request carries only its own change.
4. Keep it to one concern per pull request, opt-in behind a `config/` presence file where behavior changes, with no growth of `AGENTS.md` beyond a pointer.
5. Include tests and live evidence, and answer upstream review within its stale window.
6. Each upstream pull request is public and outward-facing, so it needs the captain's go-ahead individually.
7. Pin the default GitHub repository for fork checkouts to the fork, and name the repository explicitly in fork-targeted pull request commands, so a fork pull request is never opened upstream by mistake.
