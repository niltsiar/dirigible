# Wiki

The backlog, the run log, and the lessons are in a local wiki: a git repo of Markdown pages in the shape of an LLM wiki (`raw/`, `wiki/`, a schema in its `CLAUDE.md`). The one tool is `scripts/wiki.py`. Its header lists each command.

## Where

`scripts/wiki.py path` prints the folder. It is `dirigible-wiki` beside the main checkout, the same from each worktree. `DIRIGIBLE_WIKI` sets another path. With no wiki, each command exits nonzero and prints the path, `scripts/wiki.py init`, and `DIRIGIBLE_WIKI`. Nothing makes a wiki by itself.

## Bootstrap

1. `scripts/wiki.py init` makes an empty wiki. It refuses an existing path.
2. `scripts/wiki.py seed` adds one item for each feature of `docs/requirements/features.md` that is not done and not dropped, and one for each numbered run item of `docs/requirements/releases.md` that names such a feature.
3. `scripts/wiki.py seed --prs` also adds the deferred and follow-up bullets of merged pull requests. It needs `gh` signed in, and it only reads.

`seed` refuses a wiki that holds an item, a lesson, a changed log page, or decision numbers.

## What it holds

- `Item` pages: one backlog item each, with a status (next, later, done, dropped). `list`, `show`, `add`, `edit`, `move`, and `take` read and change them.
- `Lesson` pages: the learning lines of one cause key. `lesson` appends, and `lessons --seen-once` lists.
- `Log` pages: the run rows and the log lines of one month. `log` appends, and `runs` prints them.
- `now`: the counts, the taken items, the open runs, and the last 15 log lines.
- The decision numbers: `reserve` adds an entry, and `numbers` prints them.
- Each `index.md` and `now.md` is generated. `scripts/wiki.py lint` fails on a page that no index links.

The wiki is local only, with no remote: the backlog holds tester notes. A run never pushes it.

## Write

A write takes its text only from a file: write the file with the Write tool and pass `--from <file>`. The guardrail hook reads the whole command text, and backticks in an argument run in the shell. The tool removes the file after its commit and keeps it after a refusal. An `add` or `edit` file has the title on line 1 (8 words or fewer), the description on line 2 (12 words or fewer), a blank line, and the body. Run `show <id>` first, and pass its hash to `edit <id> --expect <hash> --from <file>`. On exit 75, run `show` again and redo the edit on the new text.

Each write takes a lock and makes one commit. A write that stopped part way leaves a dirty wiki tree, and the next write refuses with the repair steps.

## What a fresh wiki cannot rebuild

`seed` gives only what the repo holds. A new machine or a fresh clone has none of these:

- The backlog items with no feature ID: tester requests, flakes, the Consider items of the gates, and user decisions.
- The `seen-once` lines of the lessons. Without them, reflect reads a second occurrence as a first one.
- The run log: the runs, their results, and the decision number reservations.
- The run folders under `.scratchpads/runs/`.

Back up the wiki folder and `.scratchpads/runs/` before you delete them.
