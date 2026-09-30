# Long autonomous runs

Read this file when one session runs several goals or an unattended loop, before the first run.

- Take the next goal from `## Next` of `.scratchpads/backlog.md` or from the order agreed in the first planning run. Close each run before you open the next one.
- The `AGENTS.md` in the context is the copy from the start of the session, and subagents get the same copy. Reflect commits change the file on disk, not that copy. Read `AGENTS.md` from disk at the start of each run.
- Each subagent prompt says that the file on disk wins over the copy in its context.
- Before the first run of an unattended loop, check that Phase 9 can run without a prompt: `git ls-remote origin` and `gh auth status`. If one fails, stack each run branch on the previous one, record it in `run.md`, and land them when the human is back.
- Use only the access that these two commands already have; leave credential stores closed.
- Each run lands on `main` green through its own pull request, so the human can stop the loop at any time and find a working app.
