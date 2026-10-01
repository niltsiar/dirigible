# Long autonomous runs

- Take the next goal from `## Next` of `.scratchpads/backlog.md` or from the order agreed in the first planning run. Close each run before you open the next one.
- Read `AGENTS.md` from disk at the start of each run, and say in each subagent prompt that the file on disk wins: reflect commits change the file on disk, not the copy in the context.
- While a subagent runs a check, a land, or a replay, do read-only work: the Phase 0-2 reading of the next goal, research, and run files. Start no build or test: timing tests fail under load. While a bench or a flake loop runs, start nothing.
- Before the first run of an unattended loop, check the access of Phase 9: `git ls-remote origin`, `gh auth status`, and an allow rule for `scripts/land.sh` in `.claude/settings.json` (add it if it is missing). If one fails, stack each run branch on the previous one, record it in `run.md`, and land them when the human is back.
- Use only the access that these two commands already have; leave credential stores closed.
- Each run lands on `main` green through its own pull request, so the human can stop the loop at any time and find a working app.
