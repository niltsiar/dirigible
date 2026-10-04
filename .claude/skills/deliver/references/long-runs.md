# Long autonomous runs

- Before a loop, write its stop predicate in the first `run.md` (for example, `## Next` has no product item); never relax it to stop.
- Take the next goal from `## Next` of `.scratchpads/backlog.md` or the agreed order, and close each run before the next.
- Read `AGENTS.md` from disk at the start of each run, and say in each subagent prompt that the file on disk wins.
- While a subagent runs a check, a land, or a replay, do read-only work: the Phase 0-2 reading of the next goal, research, and run files. Start no build or test: timing tests fail under load. While a bench or a flake loop runs, start nothing.
- Before the first run of an unattended loop, check the access of Phase 9: `git ls-remote origin`, `gh auth status`, an allow rule for `scripts/land.sh` in `.claude/settings.json` (add it if missing), and a permission mode that allows file edits. If one fails, stack each run branch on the previous one, record it in `run.md`, and land them when the human is back.
- Use only the access that these two commands already have; leave credential stores closed.
- Each run lands green on `main` through its own pull request, so the human can stop the loop at any time.
- At a pause, leave each open run at a slice commit or with its working tree as is, and write the next step in `run.md`; make no `wip` commit.
