# Long autonomous runs

- Before a loop, write its stop predicate in the first `run.md` (for example, `scripts/wiki.py list next` has no product item); never relax it to stop.
- Take the next goal from `scripts/wiki.py list next --ready`, else the next open item of `docs/requirements/releases.md`, and close each run before the next. The cadence of the steering runs is in `docs/workflow/release-cycle.md`.
- Read `AGENTS.md` from disk at the start of each run.
- At most two runs are in code and one in planning; run `scripts/with-lock.sh --builders` to list the building trees. A third tree waits in `scripts/with-lock.sh`. A push check, a land, or a mutant runs alone: beside it, run only the code gate reviewers and read-only work: the Phase 0-2 reading of the next goal, research, run files, built files, and evals except `agent`-type rows. Start an `agent` eval row after it ends. Start no build or test in any worktree, and no on-screen check: timing tests fail under load. While a bench or a flake loop runs, start nothing.
- Before the first run of an unattended loop, check the access of Phase 9: `git ls-remote origin`, `gh auth status`, an allow rule for `scripts/land.sh` in `.claude/settings.json` (add it if missing), and a permission mode that allows file edits. If one fails, stack each run branch on the previous one, record it in `run.md`, and land them when the human is back.
- Use only the access that these two commands already have; leave credential stores closed.
- Each run lands green on `main` through its own pull request.
- At a pause, leave each open run at a slice commit or with its working tree as is, and write in `run.md` the next step and each check result, taken from its command output or log, not from memory; make no `wip` commit.
