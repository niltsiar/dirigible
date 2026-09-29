# AGENTS.md

Dirigible is a native macOS podcast recorder and editor, modeled on Hindenburg PRO. It runs on macOS 14 Sonoma and later. It records several audio devices and other apps (for example a call in Teams or Zoom) at the same time, each to its own track, without an aggregate device. The product brief and requirement IDs are in `docs/requirements/brief.md`. The release order is in `docs/requirements/releases.md`.

## Communication

- Write every document, plan, ledger row, review finding, code comment, and commit message in ASD-STE100 Simplified Technical English. Use the **technical-writing** skill, and the **unslop** skill for AI tells.
- STE in short: one idea per sentence, 20 words or fewer for an instruction, active voice, imperative for instructions, one word for one meaning, keep "the" and "a".
- Code, docs, and commits are English. The app UI is English (default) and Spanish (R13).

## Commands

| Command | What it does |
|---|---|
| `make setup` | Enables the pre-commit hook in `.githooks/` (format check and debug build). Run it once per clone. |
| `make build` | Debug build with `swift build`. |
| `make test` | Runs all tests except `AppBundleTests`. Fast. Use it in the red-green loop. `DirigibleCLITests` runs in a second process, because its synchronous waits block the concurrency pool. A bare `swift test` fails `AppBundleTests` on purpose. |
| `make test-slow` | Runs `check-slow-gates` and `make test` (two processes), then the slow tests (disk images, the finalize benchmark) with `DIRIGIBLE_SLOW_TESTS=1` in a third process, one at a time. Put the `func` of a slow test on the line after its gate. `make check` does not run the slow tests. Run it before the push of a branch that changes `Sources/`. |
| `make app` | Release build of `build/Dirigible.app` (universal, ad-hoc signed). |
| `make icon-preview` | Compiles `Support/AppIcon.icon` only (no Swift build) and writes `build/icon-preview/`: the flat renditions of macOS 14 and 15 (`flat.iconset`) and the macOS 26 looks (Light, Dark, TintedLight, TintedDark, ClearLight, ClearDark) at 1024 px. Use it to review a change of the icon (decision 0026). |
| `make bench FILTER=<test>` | Runs the slow tests that match `FILTER` in an optimized build (no `DEBUG`), in a copy of the package in `.build/bench`. `swift test -c release` runs the `@main` of the app, not the tests. |
| `scripts/bench-pairs.sh <main worktree> <filter> <pairs> <out>` | Runs `make bench` for `<filter>` in main and in this tree in alternate pairs, after an A/A pair of main, and gives each case VERIFIED, NOT VERIFIED, or INCONCLUSIVE against the 0022 rule. Make the main worktree with `git worktree add --detach <path> main`. |
| `make test-app` | Builds the app, then runs `AppBundleTests` on that bundle. |
| `make run` | Builds the app, quits a running copy, and opens the new one. |
| `make lint` | `swift format lint --strict` on all Swift files. |
| `make format` | Formats all Swift files in place. |
| `make check-docs` | Checks the docs: every research file has a date and a Sources section, every brief ID has a row in a release table of `releases.md`, every answered question links to an existing, accepted decision, and each `make` target in this table has one row and a `Makefile` target. `scripts/check-docs.test.sh` tests the check. |
| `swift run dirigible --help` | Builds and runs the command-line tool. It makes, changes, and reads session packages (decision 0011). |
| `make check-warnings` | Checks that each target in `Package.swift` treats warnings as errors, with no exception for one warning and no unsafe flag. `scripts/check-warnings.test.sh` tests the check. |
| `make check` | `lint`, `check-docs`, `check-slow-gates` (each slow-test gate has its `func` on the next line), `check-warnings`, `test`, `test-hooks`, and `test-app`. Run it before every commit. It must be green. |

The toolchain is Xcode 26 with Swift 6.2. There is no Xcode project. See `docs/decisions/0001-native-swift-stack.md`.

## How to work

Use the **deliver** skill for every feature, requirement, or bug. It runs these phases: open the run, analyze, plan, plan gate, implement test-first, clean up, code gate, verify, reflect, land.

| Skill | Use |
|---|---|
| `deliver` | The full flow. Start here. |
| `architect` | Design types and module shape before code, for one-way decisions. |
| `interrogate` | Review panel on a plan or a diff (runs the `review-panel` workflow). |
| `tdd` | Failing test first, then the code. |
| `deslop` | Remove AI code slop from the branch. |
| `verify-this` | Prove a claim with real artifacts. |
| `reflect` | Turn session learnings into commits on skills and this file. |
| `technical-writing`, `unslop` | Writing rules. |
| `bro` | The user asks you to restate your last message in plain words. |

Reviewer agents in `.claude/agents/`: `premortem`, `devils-advocate`, `architecture-reviewer`, `code-quality-reviewer`. The principles that skills cite are in `docs/principles.md`.

## Run ledger in .scratchpads/

`.scratchpads/` is gitignored. It keeps the working memory of the agents between sessions.

```
.scratchpads/
  ledger.md                 one line per run: run, goal, status, result
  learnings.md              one line per applied learning: date, learning, commit
  backlog.md                deferred work and "Consider" review items
  runs/<date>-<slug>/
    run.md                  status, phases, slices, manual checks, summary
    analysis.md, plan.md, design.md
    review-plan-<n>.md, review-diff-<n>.md
    decisions.tsv           ts, phase, decision, why, evidence, result
  verify/<claim>/           evidence from verify-this
```

- Start a run with `.claude/skills/deliver/scripts/new-run.sh <slug>`.
- Read `learnings.md`, `backlog.md`, and the last `run.md` at the start of every session.
- `decisions.tsv` is append-only. Add rows with `.claude/skills/deliver/scripts/log-decision.sh`, which writes the time from the clock. A wrong row gets a new row that corrects it.
- Never put recordings of real voices in git. Keep them in `.scratchpads/`.
- Run every probe with `scripts/probe.sh <folder> <command>`. The folder is a new folder under `.scratchpads/` (in a worktree, also of the main checkout) or the session scratchpad. The script runs the command in that folder and a sandbox refuses a write outside it. A probe once deleted files in `~`. For a Swift build in a probe, read the header of `scripts/probe.sh` first: it needs flags.
- The Bash tool shell is zsh. zsh ties `path` to `PATH` (also `status` and `argv`), so a variable with one of these names breaks every later command with "command not found". Use another name, or run the loop under `bash -c '...'`.

## Git

- The code is on GitHub: https://github.com/niltsiar/dirigible (`origin`). Use the `gh` CLI for pull requests.
- Never commit on `main` directly. Work on a branch `<type>/<slug>`. Every run lands through a pull request that `deliver` Phase 9 opens and merges with `gh pr merge --rebase`, so history on `main` stays linear and keeps each commit.
- Use Conventional Commits: `feat`, `fix`, `test`, `refactor`, `perf`, `docs`, `build`, `chore`, `style`. Add a scope when it helps: `feat(capture): ...`.
- One commit is one logical change that builds and passes `make check`. The subject is imperative and under 72 characters. The body says why. For a long message, write it to `.scratchpads/commit-msg.txt` and run `git commit -F .scratchpads/commit-msg.txt`.
- The pre-commit hook refuses a commit that fails `make lint` or does not build (tests included). It checks the working tree, so stage whole changes.
- `.claude/hooks/git-guardrails.sh` blocks git commands that discard work or skip checks: force push, push to `main`, hard reset, clean, forced branch delete, stash drop, skipped hooks, and a `git commit` joined to `make check` by anything but `&&`. It matches the whole command, so a commit message that quotes one of these flags is blocked too. Reword the message. `make test-hooks` checks the hook, `scripts/probe.sh`, `scripts/hid.swift`, `scripts/bench-pairs.sh`, `scripts/icon.sh`, and the mutation runner of the deliver skill.
- The hook allows `git checkout <path>` and `git restore <path>`, because they are useful. These hard rules apply to them and to any command that overwrites a file in the working tree:
  - First run `git status --porcelain <path>` and `git diff <path>`.
  - If the path has changes that you did not make, or that no commit or copy holds, commit them or copy them first.
  - Never discard uncommitted work of the user or of another agent.
  - A mutation control restores its file from a hash-checked copy (`mutate.py`), never from git.
- `.claude/settings.json` allows the build, test, git, and `gh pr` commands of the deliver flow without a prompt. Long runs also need a permission mode that allows file edits, for example auto mode.

## Architecture rules

- **Simple first.** Choose the simplest design that meets the requirement. No protocol with one conformer, no factory for one product, no configuration for a value that never changes.
- **Modules are SwiftPM targets.** The compiler enforces the dependency direction. The domain module (session, tracks, clips, edits) imports only Foundation. It never imports AppKit, SwiftUI, or AVFoundation. UI depends on domain, never the reverse.
- **Thin app target.** The `DirigibleApp` executable target holds only the SwiftUI shell and wiring. Logic lives in library targets that integration tests can drive.
- **Validate at boundaries.** Files, audio devices, and user input are boundaries. Parse them into domain types there. Inside, trust the types.
- **Concurrency.** UI state is `@MainActor`. File I/O and DSP run off the main actor. Each capture device has its own writer. Nothing on a real-time audio thread allocates, locks, logs, does file I/O, or awaits. Define every audio callback (render block, tap, input proc) in a `nonisolated` context and mark it `@Sendable`. In Swift 6, a closure written inside `@MainActor` code inherits main-actor isolation. Through a C function pointer, the runtime check crashes the app when Core Audio calls it on its own thread. Through a block API, it is a data race with no signal, and a removed block listener keeps getting calls. For Core Audio, use the C APIs with a static callback function of a nonisolated type (decision 0013). In an actor, each `await` lets another call run. Make the whole state change before the first `await`, or check the guard again after each `await`.
- **No data loss.** Audio that the app captured stays on disk and readable after a crash, a device unplug, or a full disk. Session saves are atomic. A WAV header gets its data size only when the file closes, so write captured audio to a format that survives a crash (for example CAF) or repair the header at launch.
- **Every device has its own clock.** Store the timing data (host time and sample time) needed to align tracks from different devices. Move a `UInt64` host time to a new base with wrapping operators (`time &- base &+ saved`). A record can come before the base, and host time is small after a boot, so the plain form traps.
- **Apple frameworks first.** Core Audio, AVFoundation, AudioToolbox, Accelerate. A third-party dependency needs a decision record in `docs/decisions/`. These frameworks report an `OSStatus`, not an `errno`. Probe the real status before code branches on it.
- **Localized UI.** Every user-facing string has an English text and a Spanish translation. No UI text is only in code. Today the only strings are the Info.plist permission texts and the session type name: English in `Support/Info.plist`, Spanish in `Support/Resources/es.lproj/InfoPlist.strings`, checked by `AppBundleTests`. UI strings go in `Support/Resources/<lang>.lproj/Localizable.strings` and views look them up in `Bundle.main`, never `Bundle.module` (decision 0010). Exception: the `dirigible` command-line text is English only, because scripts and agents compare it (decision 0011).
- **CLI parity.** Each new public library feature that operates on a session package or an audio file (an edit, an import, a render, or an export) gets a `dirigible` command and a `DirigibleCLITests` test in the same run. `ParityTests` checks the public mutating methods of `DirigibleCore`. Another public feature gets one line in its run that says why it has no command. The CLI parses, calls the library, and prints. Logic that it needs goes into a library (decision 0011).
- **No warnings.** Each target of this package treats compiler warnings as errors (`Package.swift`, SE-0480). Fix a warning at its cause. Never add a flag or an exception that hides it.
- **File size.** A Swift file over 400 lines needs a reason. Split by responsibility, not by execution order.

## Testing rules

- Write the failing test first (the **tdd** skill). Every behavior change comes with a test that fails without it.
- Prefer integration tests: drive a module through its public API with real files on disk and real audio buffers. Unit tests only for pure functions with many edge cases.
- Generate audio fixtures in the test (sine, silence, noise at a known level). Do not commit large binary fixtures.
- Assert literal expected values. For processed audio, assert with a stated tolerance, for example "level is -16 LUFS ± 0.5".
- A test that still passes when the code under test returns nothing is not a test. Rewrite it or delete it.
- Tests do not use the network, the real microphone, or a permission prompt. Hardware checks go in the run ledger as manual checks.
- Keep the suite fast. Put a slow test behind `DIRIGIBLE_SLOW_TESTS=1`. `make test-slow` runs it.

## Keep this file true

When a learning repeats, the **reflect** skill changes this file, a skill, or a check. Prefer a check (a test, a lint rule, a script) over a new sentence. Commands and paths in this file must work at every commit.
