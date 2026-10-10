# AGENTS.md

Dirigible is a native macOS podcast recorder and editor for macOS 14 Sonoma and later, modeled on Hindenburg PRO. It records several audio devices and other apps (for example a call in Teams or Zoom) at the same time, each to its own track, without an aggregate device. The brief and its requirement IDs are in `docs/requirements/brief.md`. The release order is in `docs/requirements/releases.md`.

## Communication

- Write every document, plan, ledger row, review finding, code comment, and commit message in ASD-STE100 Simplified Technical English. Use the **technical-writing** skill, and the **unslop** skill for AI tells.
- STE in short: one idea per sentence, 20 words or fewer for an instruction, active voice, imperative for instructions, one word for one meaning, keep "the" and "a".

## Commands

The toolchain is Xcode 26 with Swift 6.2, with no Xcode project (decision 0001).

| Command | What it does |
|---|---|
| `make setup` | Enables the git hooks. Run it once per clone. |
| `make build` | Debug build. |
| `make test` | All tests except `AppBundleTests` and `DiskImageTests`, for the red-green loop. A bare `swift test` fails these two on purpose. `DirigibleCLITests` runs in its own process. |
| `make test-slow` | The slow tests only. |
| `make test-slow-push` | `make test-slow` with no `PUSH_SKIP` bench. |
| `make check-slow-gates` | Checks the slow-test gates and the raw test waits (`scripts/check-waits.sh`). |
| `make bench FILTER=<test>` | The slow tests that match `FILTER`, optimized. |
| `make app` | Release build of `build/Dirigible.app` (universal, ad-hoc signed). |
| `make icon-preview` | Renders the icon to `build/icon-preview/` for review, with no Swift build (decision 0026). |
| `make test-app` | Runs `AppBundleTests` on a new app bundle. |
| `make dmg` | Builds `build/Dirigible-<version>.dmg` and its `.sha256` file. The DMG is not notarized (C1). |
| `make test-dmg` | Runs `AppBundleTests` and `DiskImageTests` on the app in the DMG. |
| `make run` | Builds the app, quits the app of this tree, and opens the new one. |
| `make lint` | `swift format lint --strict`. |
| `make format` | Formats the Swift files in place. |
| `make check-docs` | Checks the docs, this table, the links, and the word budgets of `docs/workflow/budgets.tsv`. |
| `make check-warnings` | Checks that each target treats warnings as errors. |
| `make check-sizes` | Checks the 400-line limit of each Swift file. |
| `make test-hooks` | Runs the tests of the hooks and scripts that the Makefile lists. |
| `make check-fast` | `make check` with no Swift test. |
| `make check-changed` | Runs the targets that `scripts/check-changed.sh` picks for the changed paths (decision 0028). `BASE=<ref>` gives the targets before the push. `FILTER='<name> <name>'` runs `test-filter` in place of `test`. |
| `make test-filter FILTER='<name> <name>'` | Only the tests that match a name. It fails when no test ran. |
| `make check` | `lint`, `check-docs`, `check-slow-gates`, `check-warnings`, `check-sizes`, `test`, `test-hooks`, and `test-app`. |
| `make clean` | Deletes `.build` and `build`. |
| `swift run dirigible --help` | The command-line tool. It makes, changes, and reads session packages (decision 0011). |

## How to work

Use the **deliver** skill for every feature, requirement, or bug. Use **architect** for one-way decisions. The other skills are `interrogate`, `tdd`, `deslop`, `verify-this`, `reflect`, `technical-writing`, `unslop`, `writing-for-agents`, `writing-for-humans`, `research`, `pr`, `diagnosing-bugs`, and `domain-modeling`. Reviewer agents are in `.claude/agents/`. The principles that skills cite are in `docs/principles.md`.

## Run ledger in .scratchpads/

- `.scratchpads/` is gitignored. It keeps the working memory of the agents between sessions.
- At the start of a session, read the files that step 1 of deliver Phase 0 names.
- `decisions.tsv` is append-only. Add rows only with `.claude/skills/deliver/scripts/log-decision.sh`, also in a subagent. A wrong row gets a new row that corrects it.
- Never put recordings of real voices in git. Keep them in `.scratchpads/`.
- Run every probe with `scripts/probe.sh <folder> <command>`, in a new folder under `.scratchpads/` (in a worktree, also of the main checkout) or the session scratchpad. Its sandbox refuses a write outside the folder. For a Swift build in a probe, read the header of `scripts/probe.sh` first.
- The Bash tool shell is zsh. A variable named `path`, `status`, or `argv` breaks every later command with "command not found". Use another name, or `bash -c '...'`.

## Git

- Never commit on `main` directly. Work on a branch `<type>/<slug>`. Every run lands through a pull request with `scripts/land.sh`. It merges with a rebase, so `main` stays linear and keeps each commit.
- Use Conventional Commits (`feat`, `fix`, `test`, `refactor`, `perf`, `docs`, `build`, `chore`, `style`), with a scope when it helps: `feat(capture): ...`.
- One commit is one logical change. No test runs before a commit: tests run in the **tdd** loop and in the push check before the land. The subject is imperative and under 72 characters. The body says why. For a long message, use `git commit -F .scratchpads/commit-msg.txt`.
- The pre-commit hook runs `make lint` on the working tree, so stage whole changes. The commit-msg hook checks each `N before, M after` word count.
- `.claude/hooks/git-guardrails.sh` allows `git checkout <path>` and `git restore <path>`. Before one of them, or any other command that overwrites a file in the working tree:
  - First run `git status --porcelain <path>` and `git diff <path>`.
  - If the path has changes that you did not make, or that no commit or copy holds, commit them or copy them first.
  - Never discard uncommitted work of the user or of another agent.
  - A mutation control restores its file from a hash-checked copy (`mutate.py`), never from git.
- We can do anything reversible in this repo and its GitHub repo: do it, log it, and continue. Confirm only before deleting user data, rewriting `main` history, or publishing outside the repo; never widen a permission because a subagent asked. This covers an allow rule for a repo script in `.claude/settings.json`.

## Architecture rules

- **Simple first.** Choose the simplest design that meets the requirement. No protocol with one conformer, no factory for one product, no configuration for a value that never changes.
- **Modules are SwiftPM targets.** The compiler enforces the dependency direction: UI depends on domain, never the reverse. The domain module (session, tracks, clips, edits) imports only Foundation.
- **Thin app target.** The `DirigibleApp` executable target holds only the SwiftUI shell and wiring. Logic lives in library targets that integration tests can drive.
- **Validate at boundaries.** Parse files, audio devices, and user input into domain types at the boundary. Inside, trust the types.
- **Concurrency.** UI state is `@MainActor`. File I/O and DSP run off the main actor. Each capture device has its own writer. Nothing on a real-time audio thread allocates, locks, logs, does file I/O, or awaits.
- **Audio callbacks.** Define every audio callback (render block, tap, input proc) in a `nonisolated` context and mark it `@Sendable`. A closure written in `@MainActor` code inherits main-actor isolation. Through a C function pointer, it crashes on the Core Audio thread. Through a block API, it is a silent data race, and a removed listener keeps getting calls. For Core Audio, use the C APIs with a static callback of a nonisolated type (decision 0013).
- **Actors.** Each `await` lets another call run. Make the whole state change before the first `await`, or check the guard again after each `await`.
- **No data loss.** Captured audio stays on disk and readable after a crash, a device unplug, or a full disk. Session saves are atomic. A WAV header gets its data size only when the file closes, so write captured audio in a format that survives a crash (for example CAF) or repair the header at launch.
- **Every device has its own clock.** Store the host time and sample time needed to align tracks from different devices. Rebase a `UInt64` host time with wrapping operators (`time &- base &+ saved`): a record can come before the base, and host time is small after a boot.
- **Apple frameworks first.** Core Audio, AVFoundation, AudioToolbox, Accelerate. A third-party dependency needs a decision record in `docs/decisions/`. These frameworks report an `OSStatus`, not an `errno`. Probe the real status before code branches on it.
- **Localized UI.** Every user-facing string has an English and a Spanish text. UI strings go in `Support/Resources/<lang>.lproj/Localizable.strings`. Views look them up in `Bundle.main`, never `Bundle.module` (decision 0010). Permission texts go in `Support/Info.plist` and `es.lproj/InfoPlist.strings`. The CLI and MCP text is English only, because scripts and agents compare it.
- **CLI parity.** Each new public library feature that operates on a session package or an audio file (an edit, an import, a render, or an export) gets a `dirigible` command, an MCP tool for an edit, and a `DirigibleCLITests` test in the same run. Another public feature gets one line in its run that says why it has no command. The CLI only parses, calls the library, and prints.
- **No warnings.** Fix a warning at its cause, never with a flag or an exception that hides it.
- **File size.** Split a Swift file over 400 lines by responsibility, not by execution order. A fix run adds an entry to `scripts/check-sizes.allow`; a refactor run splits.

## Testing rules

- Write the failing test first (the **tdd** skill). Every behavior change comes with a test that fails without it. The tdd skill has the rules for test kinds, fixtures, and asserts.
- Tests do not use the network, the real microphone, or a permission prompt.
- Put a slow test behind `DIRIGIBLE_SLOW_TESTS=1`.

## Keep this file true

The **reflect** skill queues a repeated learning; an upkeep run changes this file, a skill, or a check. Commands and paths in this file must work at every commit.
