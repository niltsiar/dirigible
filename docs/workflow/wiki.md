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

- `Item` pages: one backlog item each, with a status (next, later, done, dropped). `list`, `show`, `add`, `edit`, `move`, `take`, `wait`, and `unwait` read and change them. Only an open run holds an item: `take` refuses an item that another open run holds, and takes it over from a run that is done, dropped, or has no folder.
- `Lesson` pages: the learning lines of one cause key. `lesson` appends, and `lessons --seen-once` lists.
- `Log` pages: the run rows and the log lines of one month. `log` appends, and `runs` prints them.
- `now`: the counts, the items that wait for the user, the taken items, the open runs, and the last 15 log lines.
- The decision numbers: `reserve` adds an entry, and `numbers` prints them.
- Each `index.md` and `now.md` is generated. `scripts/wiki.py lint` fails on a page that no index links.

The wiki is local only, with no remote: the backlog holds tester notes. A run never pushes it.

## Write

A write takes its text only from a file: write the file with the Write tool and pass `--from <file>`. The guardrail hook reads the whole command text, and backticks in an argument run in the shell. The tool removes the file after its commit and keeps it after a refusal. An `add` or `edit` file has the title on line 1 (8 words or fewer), the description on line 2 (12 words or fewer), a blank line, and the body. Run `show <id>` first, and pass its hash to `edit <id> --expect <hash> --from <file>`. On exit 75, run `show` again and redo the edit on the new text.

Each write takes a lock and makes one commit. `init` turns off commit signing in the local config of the wiki repo only: the wiki has no remote, and a signing prompt would block an unattended write. A write that stopped part way leaves a dirty wiki tree, and the next write refuses with the repair steps.

## Items that wait

An item can wait. Its optional `waits:` field holds one target:

- `user`: the item waits for a decision or an action of the user. It stays hidden until `unwait`.
- `item:<id>`: the item waits for another item. The wait ends when that item is done or dropped.
- `run:<run folder>`: the item waits for a run. The wait ends when `run.md` of that run in the main checkout has a status line of done or dropped (`- Status: done (PR ...)` counts), or when that run folder does not exist.

`wait <id> <target>` sets the field and `unwait <id>` clears it. `wait` refuses a missing item, a target item that does not exist, and a cycle, and it writes nothing then. `edit` and `move` leave the field unchanged.

`list next --ready` hides each item whose target is still open. Phase 0 of the deliver skill reads this list. `list <status>` with no flag shows every item, each with its `(waits: <target>)` value. `now` prints a line with the number and the IDs of the next and later items that wait for the user. `lint` fails on a `waits:` value that is no kind, a bad run folder name, or a missing item.

## What a fresh wiki cannot rebuild

`seed` gives only what the repo holds. A new machine or a fresh clone has none of these:

- The backlog items with no feature ID: tester requests, flakes, the Consider items of the gates, and user decisions.
- The `seen-once` lines of the lessons. Without them, reflect reads a second occurrence as a first one.
- The run log: the runs, their results, and the decision number reservations.
- The run folders under `.scratchpads/runs/`.

Back up the wiki folder and `.scratchpads/runs/` before you delete them.
