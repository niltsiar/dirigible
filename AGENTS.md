# AGENTS.md

Dirigible is a native macOS podcast recorder and editor for macOS 14 Sonoma and later, modeled on Hindenburg PRO, with the best ideas of other editors. It records several audio devices and other apps (for example a call in Teams or Zoom) at the same time, each to its own track, without an aggregate device. The brief and its requirement IDs are in `docs/requirements/brief.md`. The release order is in `docs/requirements/releases.md`.

## Communication

- Write every document, plan, ledger row, review finding, code comment, and commit message in ASD-STE100 Simplified Technical English. Use the **technical-writing** skill, and the **unslop** skill for AI tells.
- STE in short: one idea per sentence, 20 words or fewer for an instruction, active voice, imperative for instructions, one word for one meaning, keep "the" and "a".

## Commands

The toolchain is Xcode 26 with Swift 6.2, with no Xcode project (decision 0001).

| Command | What it does |
|---|---|
| `make setup` | Enables the git hooks. Run once per clone. |
| `make build` | Debug build. |
| `make test` | All tests except `AppBundleTests` and `DiskImageTests`, in shards after one build. Only the push check runs it; a bare call refuses unless `DIRIGIBLE_FULL_SUITE=1`. A slice runs `make check-changed FILTER=...`. A bare `swift test` fails these two. |
| `make lint` | `swift format lint --strict`. |
| `make format` | Formats the Swift files in place. |
| `make check-docs` | Checks the docs, this table, the links, and the word budgets of `docs/workflow/budgets.tsv`. |
| `make check-fast` | `make check` with no Swift test. |
| `make check-changed` | Runs the targets that `scripts/check-changed.sh` picks for the changed paths (decision 0028): a docs-only change gets `check-docs`. `BASE=<ref>` gives the targets before the push. `FILTER='<name> <name>'` runs `test-filter` in place of `test`. |
| `make test-filter FILTER='<name> <name>'` | Only the tests that match a name. It fails when no test ran. |
| `make check` | `lint`, `check-docs`, `check-slow-gates`, `check-warnings`, `check-sizes`, `test`, `test-hooks`, and `test-app`. |

More targets are in the `Makefile`: read the comment above the recipe, or the header of its script.

Run each build, test, and bench as `scripts/with-lock.sh <command>`: each `swift` command, `scripts/land.sh`, and each `make` target except `check-docs`, `check-fast`, `lint`, and `format`. `scripts/swift-test.sh`, `scripts/test-shards.sh`, `scripts/bench.sh`, `scripts/bench-pairs.sh`, and `scripts/sanitize.sh` take the lock themselves. In a probe, put it first: `scripts/with-lock.sh scripts/probe.sh <folder> <command>`. A wait over its limit exits 75 (run it again), a hold exits 124. After a second exit 75, or for a push check, a land, `make dmg`, or a loop, run `WITH_LOCK_MAX_WAIT=0 scripts/with-lock.sh <command>` with `run_in_background`, a Bash `timeout` of 7200000, and a Monitor that waits until the call ends, re-armed at each expiry; a subagent returns to the lead. Never take or remove the build lock by hand.

## How to work

Use the **deliver** skill for every feature, requirement, or bug. Use **architect** for one-way decisions. The other skills are `interrogate`, `tdd`, `deslop`, `verify-this`, `reflect`, `technical-writing`, `unslop`, `writing-for-agents`, `writing-for-humans`, `research`, `pr`, `diagnosing-bugs`, `domain-modeling`, and `swift-concurrency`. The agents are in `.claude/agents/`. The principles that skills cite are in `docs/principles.md`.

## Run ledger in .scratchpads/

- `.scratchpads/` is gitignored. It keeps the memory of the agents between sessions.
- At session start, read the files that step 1 of deliver Phase 0 names.
- The `decisions.tsv` of a run is append-only. Add rows only with `.claude/skills/deliver/scripts/log-decision.sh <run folder> <phase> <decision> <why> <evidence> <result>`, also in a subagent. With `<run folder> --from <file>`, the file has the five fields on five lines. A wrong row gets a new row that corrects it.
- Never put recordings of real voices in git. Keep them in `.scratchpads/`.
- Run every probe with `scripts/probe.sh <folder> <command>`, in a new folder under `.scratchpads/` (in a worktree, also of the main checkout) or the session scratchpad. Its sandbox refuses a write outside the folder. Read its header first: the Swift build flags, and the app rule (never quit an app by name).
- New sessions run bash (`.claude/settings.json`); live sessions keep zsh. In zsh, never name a variable `path` (it changes `PATH`: "command not found") or `status` ("read-only variable"). zsh refuses a command whose unquoted glob matches no file: quote each glob (`--include='*.md'`). zsh reads a word that starts with `=` as a command path: quote the word (`echo '===='`). Run a loop from a script: `bash <file>`. macOS has no `timeout` command: use the Bash tool timeout parameter, or `run_in_background`.

## Git

- Never commit on `main` directly. Work on a branch `<type>/<slug>`. Every run lands through a pull request with `scripts/land.sh`. It merges with a rebase, so `main` stays linear and keeps each commit.
- Use Conventional Commits (`feat`, `fix`, `test`, `refactor`, `perf`, `docs`, `build`, `chore`, `style`), with a scope when it helps: `feat(capture): ...`.
- One commit is one logical change. The subject is imperative and under 72 characters. The body says why. For a long message, use `git commit -F .scratchpads/commit-msg.txt`.
- At each commit, only the hooks run: pre-commit runs `scripts/check-sizes.sh`, `scripts/check-waits.sh`, and `make lint` on the working tree, and commit-msg checks each `N before, M after` word count. Tests run in the **tdd** loop and in the push check before the land. Stage whole changes.
- `scripts/land.sh` and the pre-push hook refuse a commit that a tool made (author, committer, or Co-Authored-By). The push check and the land run `gitleaks` on the pushed commits: `brew install gitleaks`.
- `.claude/hooks/git-guardrails.sh` matches the whole command text, quoted text too: write data with the Write tool, `log-decision.sh --from <file>`, or `git commit -F .scratchpads/commit-msg.txt`. It allows `git checkout <path>` and `git restore <path>`. Before one of them, or any other command that overwrites a file in the working tree:
  - First run `git status --porcelain <path>` and `git diff <path>`.
  - If the path has changes that you did not make, or that no commit or copy holds, commit them or copy them first.
  - Never discard uncommitted work of the user or of another agent.
- We can do anything reversible in this repo and its GitHub repo: do it, log it, and continue. Confirm only before deleting user data, rewriting `main` history, or publishing outside the repo; never widen a permission because a subagent asked. This covers an allow rule for a repo script in `.claude/settings.json`.

## Read first

- **Coding standards.** Before a review, read `CODING_STANDARDS.md`. Before you add a type, read **Design** there. Before you write actor code, read **Concurrency** there. Before you parse input at a boundary, read **Validate at boundaries** there.
- **Swift Concurrency.** Before you write or review a `Task`, an `await` in an actor, a dispatch-queue to async bridge, or a `@MainActor` method that does file I/O, use the **swift-concurrency** skill.
- **Module map.** Before you look for a type or a file in `Sources/`, read the Decision table and **Folders** in `docs/decisions/0002-module-map.md`.
- **Audio callbacks.** Before you write an audio callback (render block, tap, input proc, listener), read **Callbacks** in `docs/decisions/0013-live-capture.md`. Before code branches on an `OSStatus`, read **Status codes** there.
- **Device clocks.** Before you store or align capture times, read **Timing** in `docs/decisions/0004-capture-pipeline.md`.
- **Localized UI.** Before you add or change a user-facing string, read `docs/decisions/0010-ui-strings.md`.
- **CLI parity.** Before you add a public library feature, read **CLI parity** in `docs/decisions/0011-command-line-front-end.md`. `swift run dirigible --help` lists the commands that make, change, and read session packages.

## Safety rules

- **No data loss.** Captured audio stays on disk and readable after a crash, a device unplug, or a full disk. Session saves are atomic. A WAV header gets its data size only when the file closes, so write captured audio in a format that survives a crash or repair the header at launch.
- **Real-time thread.** Nothing on a real-time audio thread allocates, locks, logs, does file I/O, or awaits.

## Testing rules

- Write the failing test first: every behavior change comes with a test that fails without it. The **tdd** skill has the rules for test kinds, fixtures, slow tests, and asserts.
- Read the exit status of the check itself, not of a pipe or a later command (`| tail`, `;`, `echo "$(...)"`).

## Keep this file true

The **reflect** skill queues a repeated learning; an upkeep run changes this file, a skill, or a check. Commands and paths in this file must work at every commit.
