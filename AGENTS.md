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
| `make test` | Runs all tests except `AppBundleTests`. Fast. Use it in the red-green loop. A bare `swift test` fails `AppBundleTests` on purpose. |
| `make app` | Release build of `build/Dirigible.app` (universal, ad-hoc signed). |
| `make test-app` | Builds the app, then runs `AppBundleTests` on that bundle. |
| `make run` | Builds the app, quits a running copy, and opens the new one. |
| `make lint` | `swift format lint --strict` on all Swift files. |
| `make format` | Formats all Swift files in place. |
| `make check-docs` | Checks the docs: every research file has a date and a Sources section, every brief ID has a row in a release table of `releases.md`, and every answered question links to an existing, accepted decision. `scripts/check-docs.test.sh` tests the check. |
| `swift run dirigible --help` | Builds and runs the command-line tool. It makes, changes, and reads session packages (decision 0011). |
| `make check` | `lint`, `check-docs`, `test`, `test-hooks`, and `test-app`. Run it before every commit. It must be green. |

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
- `decisions.tsv` is append-only. A wrong row gets a new row that corrects it.
- Never put recordings of real voices in git. Keep them in `.scratchpads/`.

## Git

- The code is on GitHub: https://github.com/niltsiar/dirigible (`origin`). Use the `gh` CLI for pull requests.
- Never commit on `main` directly. Work on a branch `<type>/<slug>`. Every run lands through a pull request that `deliver` Phase 9 opens and merges with `gh pr merge --rebase`, so history on `main` stays linear and keeps each commit.
- Use Conventional Commits: `feat`, `fix`, `test`, `refactor`, `perf`, `docs`, `build`, `chore`, `style`. Add a scope when it helps: `feat(capture): ...`.
- One commit is one logical change that builds and passes `make check`. The subject is imperative and under 72 characters. The body says why. For a long message, write it to `.scratchpads/commit-msg.txt` and run `git commit -F .scratchpads/commit-msg.txt`.
- The pre-commit hook refuses a commit that fails `make lint` or does not build (tests included). It checks the working tree, so stage whole changes.
- `.claude/hooks/git-guardrails.sh` blocks git commands that discard work or skip checks: force push, push to `main`, hard reset, clean, forced branch delete, stash drop, skipped hooks. It matches the whole command, so a commit message that quotes one of these flags is blocked too. Reword the message. `make test-hooks` checks the hook.
- `.claude/settings.json` allows the build, test, git, and `gh pr` commands of the deliver flow without a prompt. Long runs also need a permission mode that allows file edits, for example auto mode.

## Architecture rules

- **Simple first.** Choose the simplest design that meets the requirement. No protocol with one conformer, no factory for one product, no configuration for a value that never changes.
- **Modules are SwiftPM targets.** The compiler enforces the dependency direction. The domain module (session, tracks, clips, edits) imports only Foundation. It never imports AppKit, SwiftUI, or AVFoundation. UI depends on domain, never the reverse.
- **Thin app target.** The `DirigibleApp` executable target holds only the SwiftUI shell and wiring. Logic lives in library targets that integration tests can drive.
- **Validate at boundaries.** Files, audio devices, and user input are boundaries. Parse them into domain types there. Inside, trust the types.
- **Concurrency.** UI state is `@MainActor`. File I/O and DSP run off the main actor. Each capture device has its own writer. Nothing on a real-time audio thread allocates, locks, logs, does file I/O, or awaits. Define every audio callback (render block, tap, input proc) in a `nonisolated` context and mark it `@Sendable`. In Swift 6, a closure written inside `@MainActor` code inherits main-actor isolation, and the runtime check crashes the app when Core Audio calls it on its own thread.
- **No data loss.** Audio that the app captured stays on disk and readable after a crash, a device unplug, or a full disk. Session saves are atomic. A WAV header gets its data size only when the file closes, so write captured audio to a format that survives a crash (for example CAF) or repair the header at launch.
- **Every device has its own clock.** Store the timing data (host time and sample time) needed to align tracks from different devices.
- **Apple frameworks first.** Core Audio, AVFoundation, AudioToolbox, Accelerate. A third-party dependency needs a decision record in `docs/decisions/`.
- **Localized UI.** Every user-facing string has an English text and a Spanish translation. No UI text is only in code. Today the only strings are the Info.plist permission texts and the session type name: English in `Support/Info.plist`, Spanish in `Support/Resources/es.lproj/InfoPlist.strings`, checked by `AppBundleTests`. UI strings go in `Support/Resources/<lang>.lproj/Localizable.strings` and views look them up in `Bundle.main`, never `Bundle.module` (decision 0010). Exception: the `dirigible` command-line text is English only, because scripts and agents compare it (decision 0011).
- **CLI parity.** Each new public library feature that operates on a session package or an audio file (an edit, an import, a render, or an export) gets a `dirigible` command and a `DirigibleCLITests` test in the same run. `ParityTests` checks the public mutating methods of `DirigibleCore`. Another public feature gets one line in its run that says why it has no command. The CLI parses, calls the library, and prints. Logic that it needs goes into a library (decision 0011).
- **File size.** A Swift file over 400 lines needs a reason. Split by responsibility, not by execution order.

## Testing rules

- Write the failing test first (the **tdd** skill). Every behavior change comes with a test that fails without it.
- Prefer integration tests: drive a module through its public API with real files on disk and real audio buffers. Unit tests only for pure functions with many edge cases.
- Generate audio fixtures in the test (sine, silence, noise at a known level). Do not commit large binary fixtures.
- Assert literal expected values. For processed audio, assert with a stated tolerance, for example "level is -16 LUFS ± 0.5".
- A test that still passes when the code under test returns nothing is not a test. Rewrite it or delete it.
- Tests do not use the network, the real microphone, or a permission prompt. Hardware checks go in the run ledger as manual checks.
- Keep the suite fast. Put slow benchmarks behind an environment variable.

## Keep this file true

When a learning repeats, the **reflect** skill changes this file, a skill, or a check. Prefer a check (a test, a lint rule, a script) over a new sentence. Commands and paths in this file must work at every commit.
