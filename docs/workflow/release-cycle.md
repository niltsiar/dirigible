# Release cycle

The steering rules of the release plan. `docs/requirements/releases.md` lists the features of each release in order. `docs/requirements/features.md` holds the state of each feature.

## Plan

- A release has one theme.
- Requests of the users and the collaborators come first (the testers are invited collaborators). The other features follow the order of `releases.md`.
- Take the next goal from `scripts/wiki.py list next --ready`, else the next open item of `releases.md`.
- A guard failure on the real repo is a plan change. Never set a Dropped state to pass a guard.

## Numbers and states

- A run that lands an F-ID takes the lowest open release and the next run number of that release. Its version is `0.<release>.<run>`. `check-governance.sh` refuses another run number.
- A feature of a later release that lands early moves to that release. The landing run moves its item in `releases.md` and writes `(moved from Release <k>)` in the state.
- The landing run names the F-IDs of the land in `- Lands:` of `run.md`, or writes `- Lands: none`. It sets the state of each of them in its own pull request. A `feat/` landing that changes `Sources/` names at least one F-ID, because `scripts/tag-release.sh` needs a done row for its run number. A run that lands in steps replaces the line before each land. `check-governance.sh` refuses the land otherwise.
- A new request gets the next free ID, and an ID is never used again. A drop sets `Dropped (<reason>)`, and the row stays.

## Steering runs

- Run reflect after each run (`.claude/skills/reflect/SKILL.md`).
- Run a workflow upkeep run when `scripts/wiki.py list next` shows 8 or more upkeep items (reflect rule 6).
- Run an architecture run after each 5 product runs, and one before the UI polish run of each release. A product run has a branch of type `feat`, `fix`, or `perf`, and no `hardening` in its slug. `new-run.sh` prints the reminder.
- The architecture run audits `Sources/` and the tooling: `scripts/`, `.claude/hooks`, `.claude/skills/*/scripts`, `.githooks`, and the `Makefile`.
- Audit the tooling for a script with no caller, a stale path or pointer, a comment that no longer matches the code, and a copied helper.
- Audit the tooling for a script with no `.test.sh` case, a failing or skipped test case, and a file near 400 lines.
- A steering run (reflect, upkeep, architecture, UI polish, hardening) takes a code slot. It ships with the fourth number when it changes app code.

## End of a release

- End a release with these steps in order: the architecture run, the UI polish run, the hardening pass, the docs coherence pass, one release post to the testers, and last, the `Status: closed` line of the release in `docs/requirements/releases.md`.
- The docs coherence pass reads `README.md`, `docs/guide.md`, `docs/CONTRIBUTING.md`, `CONTEXT.md`, `docs/requirements/`, and the docs map against each other and the code. It fixes each contradiction, each term with two names, each menu table out of menu order, each duplicate or misplaced section, and each stale behavior claim, in one docs run with the doc lenses.
- The UI polish run asks the UI panel: UI expert agents for Hindenburg PRO, Logic Pro, GarageBand, and Final Cut Pro.

## Posts

- After each tag, `scripts/tag-release.sh` prints one reminder: post the DMG to the testers, and after the last run of a release, run the docs coherence pass, post the release summary, and close the release.
- The post is by hand: no script in the repo posts it.

## Rules that continue from Release 2

- Each run lands through its own pull request.
- Three rules have their own home: the guide and the screenshots (`docs/CONTRIBUTING.md`, "Keep the docs true"), the CLI and MCP parity (`docs/decisions/0011-command-line-front-end.md`), and the bench limit (`scripts/bench-pairs.sh`).
- Each command has a menu item with a key (F16).
- A run that adds user data to `session.xml` raises `sessionVersion` to the next free number, in land order (0024).
