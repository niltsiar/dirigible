# Research: reference projects (Compositor, IceCubes, and other Swift apps)

Date: 2026-10-01

Method: `gh api` and raw files, 2026-10-01. "Read" = I read the text; "listing" = file names only; NOT VERIFIED = unchecked. Already known, not repeated: NetNewsWire `CLAUDE.md`, Dimillian/Skills, Hudson and AvdLee skills, cursor/plugins, mattpocock/skills.

## 1. The photo-editor reference: Compositor

- Found in the first user session (transcript `7c81479a`): "get inspiration https://github.com/robbietilton/Compositor ... it tried to do something similar with Photoshop and it got really good results". The repo has no mention of it in `docs/` (history grep for "photo" found nothing relevant).
- Repo: https://github.com/robbietilton/Compositor. MIT. About 6.8k stars. Swift (SwiftUI and AppKit, some C and Metal). "The Photoshop alternative for Mac". Pushed 2026-09-29. Needs macOS 26 and Apple silicon.
- Agent files (read): `AGENTS.md`, 15 lines, no `CLAUDE.md`, no `.claude`, no `.cursor`. It has two parts. Part 1 is for an agent that edits a user's project: "you don't need the app's source code", read `docs/writing-comp-files.md`. Part 2 is for work on the app: build and test commands, "match the surrounding code", American spelling, and "a change to what's saved means a format version bump" in `docs/project-format.md` and `ProjectManifest.current`.
- Product idea that is agentic: a `.comp` project is a folder of PNG layers and a `manifest.json`. The open app reloads it within about 0.5 s of a file write. An agent edits the file and the user watches the canvas. `docs/writing-comp-files.md` is the contract (format, load rules, safe write while open).
- Engineering (read or listing): Xcode project (`Compositor.xcodeproj`), `SWIFT_VERSION = 5.0`, target macOS 26. About 40 test files in `CompositorTests` (Swift Testing, "171 tests in 25 suites" per `docs/brush-performance.md`). One CI workflow `verify.yml` on `macos-26`: select Xcode, resolve packages with `-onlyUsePackageVersionsFromResolvedFile`, `build-for-testing`, test; concurrency group cancels old runs; PR runs only for forks to avoid double runs. `scripts/release.sh` builds, signs with Developer ID, notarizes, staples, makes the DMG. `appcast.xml` (Sparkle feed).
- `docs/brush-performance.md` (read) gives a measured before and after table (median, p95), sizes, a "Reproduce" command with an env gate, and "run performance tests alone". Same idea as our 0022 rule.

Good practice we lack:
1. A documented, machine-readable file contract for agents. Our session package has a CLI (decision 0011), but no "how an agent edits a `.dirigible` package by hand" doc.
2. A live-reload loop: an external write shows in the open app. We have none (NOT VERIFIED whether our app watches the package).
3. A format version rule in AGENTS.md: "a change to what is saved bumps the version". Check whether ours exists in decision 0003.

Conflicts: macOS 26 only and Apple silicon (we target 14+ on Intel); Xcode project (we have none); `SWIFT_VERSION = 5.0` (our Swift 6 and zero warnings are stricter); Developer ID and notarization (we have no account). Take the doc patterns, not the setup.

## 2. IceCubesApp

- https://github.com/Dimillian/IceCubesApp. AGPL-3.0 (copying code is a licence problem for us; patterns only). About 7k stars. Pushed 2026-09-20. Mastodon client, iOS, iPadOS, macOS, visionOS.
- Agent files (read): `CLAUDE.md` (about 200 lines). `AGENTS.MD` returned 404 under that name in raw (the listing shows `AGENTS.MD`; NOT VERIFIED content, likely a pointer). No `.claude`, `.cursor`, or Copilot file. Content: build and test commands through the XcodeBuildMCP tool with a hard-coded local path; module list; "new features should NOT use ViewModels"; SwiftUI state rules; DO and DON'T lists ("Add abstraction layers without clear benefit", "Do not nest @Observable objects"); testing strategy in 5 lines ("Don't sacrifice code clarity for testability").
- Engineering: 12 local Swift packages in `Packages/` (Models, Network, Env, DesignSystem, Timeline, ...), each with its own tests. The `Timeline` Package.swift is `swift-tools-version: 6.2`, `.swiftLanguageMode(.v6)`, `.defaultIsolation(MainActor.self)`, third-party packages pinned with `exact:`. One CI workflow, `validate_translations.yml`. `ci_scripts/` for Xcode Cloud. `.swiftformat` (2-space). `dependabot.yml`. A Xcode project hosts the app.
- Lacking in ours: a CI check of the localization files (we have only local `AppBundleTests`).
- Conflicts: `defaultIsolation(MainActor.self)` changes how closures inherit isolation. Our AGENTS.md concurrency rule says audio callbacks must be `nonisolated`; a default of MainActor in the audio targets would hide that error. Do not adopt for audio targets. The XcodeBuildMCP and hard-coded paths do not fit (no Xcode project). "No ViewModels" is a UI choice, not a rule for us: our logic lives in library targets.
- Verdict: weaker agent text than ours. Little to adopt.

## 3. Other projects (verified from the repo)

| Project | Link | Licence | Agent or contributor files (read or listing) | What to learn |
|---|---|---|---|---|
| AltTab | https://github.com/lwouis/alt-tab-macos | GPL-3.0 | `AGENTS.md` (read), `CLAUDE.md` is `@include ./AGENTS.md`, `.claude/skills/` (5 skills, listing), `ai/{build,test,profile,run}.sh`, `docs/` | Best agent file found. See below. |
| NetNewsWire | https://github.com/Ranchero-Software/NetNewsWire | MIT | `CLAUDE.md` (read), `CONTRIBUTING.md`, `.swiftlint.yml`, `NetNewsWire-CI.xctestplan` | Modules in `/Modules` (RSCore, RSParser, RSWeb); one script builds and tests all. Known. |
| AudioKit | https://github.com/AudioKit/AudioKit | MIT | `CLAUDE.md` (read) | Audio tests, section 4. |
| AudioSnapshotTesting | https://github.com/AudioKit/AudioSnapshotTesting | MIT | README (read) | Swift Testing library; snapshots of waveform, spectrum, spectrogram images. |
| Waveform | https://github.com/AudioKit/Waveform | MIT | README only (read) | "GPU accelerated SwiftUI waveform view": `Waveform.metal`, `Renderer.swift`, `SampleBuffer.swift`. A pattern for our timeline waveform (NOT VERIFIED how it draws; I read file names only). |
| AudioCap | https://github.com/insidegui/AudioCap | BSD-2-Clause | README (read) | Sample of the macOS 14.4 Core Audio process tap, "poorly documented". Same API as our app-capture feature (R2). Read it before our own tap code. |
| Sparkle | https://github.com/sparkle-project/Sparkle | NOASSERTION (mixed) | listing: `Package.swift`, `Tests`, `UITests`, `.swiftlint.yml` | Update framework; a decision record is needed (no notarization now, so low value). |
| CodeEdit, Ice, Loop, Whisky, IINA, Stats, Maccy, CotEditor | repo roots listed | MIT (CodeEdit, Stats, Maccy), GPL-3.0 (Ice, Loop, Whisky, IINA), CotEditor NOASSERTION | Listing only: no `AGENTS.md`, no `CLAUDE.md`, no `.claude` in any. Several have `.swiftlint.yml` and `CONTRIBUTING.md`. | Nothing agentic. Contributor docs only. IINA (media) and CotEditor not read in depth: NOT VERIFIED. |

AltTab `AGENTS.md` (read) has four points that fit us:
- "Main-thread IPC": ordinary AppKit calls can block on XPC; a text-field reset froze a main thread 3.0 s. Rules: AppKit responders are main-thread only; do visible work first on latency paths; a Core Animation commit happens when the run loop turn ends. `MainThreadStall.step()` names a long main-thread call in the log.
- "Comments": write for low drift, comment what the code cannot show (OS behavior, measured timings, invariants), no history in comments, state a rule once at the widest scope, and a `/rework-comments` skill to audit.
- "Triad": specs in `*Specs.md`, tests in `*Tests.swift`, code in `*.swift`; skill `audit-specs-tests`.
- `ai/*.sh` scripts for build, test (1.3 s against 34 s for the CI script), profile, run; and a worktree note (copy the gitignored local config).
Conflicts: "no SwiftUI", "Swift 5.8", "compact code with no blank-line groups", GPL-3.0 (do not copy text into an MIT or private repo without checking our licence). Style rules clash with our STE and `swift format --strict`.

## 3b. Scan of the awesome-macos lists

Both lists exist: https://github.com/sozercan/awesome-macos (current, pushed 2026-06-24) and https://github.com/sozercan/awesome-macos-1 (a fork of yauhenipakala/awesome-macos; skip it). I took 147 GitHub repos from the README of the first, kept those with language Swift, not archived, pushed since 2026-03 (34 repos; the list has no audio app of note), and read the root listing of each. 10 have an agent file:

| Repo | Licence | File | What is useful |
|---|---|---|---|
| TableProApp/TablePro | AGPL-3.0 | `AGENTS.md` (134 lines, read), `CLAUDE.md`, `.claude/rules/` (17 path-scoped rule files), `.claude/skills/{fix-issue,release}`, `.agents/` | Best structure found. `AGENTS.md` is the index; each area rule loads by `paths:` front matter only when the agent touches that path. A wrapper `verify.sh build/test/lint` keeps the full log on disk and prints PASS, FAIL, or INCONCLUSIVE. It has an `agent-docs` check (the docs check of agent files; NOT VERIFIED how it works). "Fix the cause, not the symptom"; "when a test fails, fix the code, never the test". |
| mas-cli/mas | MIT | `AGENTS.md` (316 lines, read) | SwiftPM CLI, Swift 6.3. "To preserve tokens, agents should skip format and lint before a commit unless told": a cost-aware rule. `Scripts/{bootstrap,format,lint,build,test,package}`. |
| paretoSecurity/pareto-mac | GPL-3.0 | `AGENTS.md` (35 lines, read), `CLAUDE.md` | Short, standard layout, Conventional Commits. Nothing new. |
| JulianKahnert/PDF-Archiver | NOASSERTION | `CLAUDE.md` (318 lines, read to line 45) | Comment rule: "explain why, max 2 lines, delete comments that restate the line". Concise PR text rules. |
| NetNewsWire | MIT | `CLAUDE.md` | Known. |
| ClashX-Pro/ClashX | AGPL-3.0 | `.claude/skills` (listing) | Not read. |
| Abhishaker17/Clocker, dustinrue/ControlPlane, nickustinov/itsypad-macos, sorkila/lockpaw | MIT or GPL | `CLAUDE.md` (listing only) | NOT VERIFIED; small apps. |

Also AltTab (section 3) is the best agent text for AppKit. Others in the 34 (CotEditor, IINA, Rectangle, MonitorControl, Cork, XcodesApp, WWDC) have no agent file (listing).

Adoption from this scan: recommendation 7 below.

## 4. AudioKit and Rogue Amoeba

**AudioKit** (https://github.com/AudioKit; the org has about 50 repos; MIT for all that I checked: AudioKit, AudioKitEX, SoundpipeAudioKit, DevoloopAudioKit, AudioKitUI, Waveform, Cookbook, Flow, AudioSnapshotTesting).
- Agent files: only `AudioKit/AudioKit` has `CLAUDE.md` (read). The others (AudioKitEX, SoundpipeAudioKit, AudioKitUI, DevoloopAudioKit, Waveform, Cookbook, Flow) have none in the root listing. No `.cursor`.
- `CLAUDE.md` content: xcodebuild commands (iOS Simulator), architecture (Node protocol over `AVAudioNode`, `AudioEngine` with headless `startTest()` and `render()`, taps), naming rules (units out of names, `is...ing` booleans, "Durations"), and the test approach: render offline, compare an MD5 hash of the buffer against a table `ValidatedMD5s.swift`; `audition()` to listen, remove before commit.
- Real-time safety: the file says nothing about locks, allocation, or threads (grep). Our AGENTS.md rule is stronger.
- Tests: MD5 of exact output is brittle across OS and CPU versions (our rule: assert levels with a tolerance). `AudioSnapshotTesting` (Swift Testing, images of waveform, spectrum, spectrogram) is the better pattern: a human reads the snapshot once. It is a dependency, so it needs a decision record; copying the idea is free.
- Waveform is a Metal view (file names only read; NOT VERIFIED how it draws). No dependency for us.
- Reuse: none now. Learn: offline render in tests (`engine.render`), the snapshot idea.

**Rogue Amoeba** (https://github.com/rogueamoeba): an organization with 3 public repos, all old and not apps:
- `Soundflower-Original`, MIT, last push 2023-01-12: "macOS system extension that allows applications to pass audio to other applications". A kernel-era virtual device, not needed (we capture without an aggregate device) and not a pattern for the process tap.
- `beardedspice` (media keys, 2016, no licence field) and `HelpManualWindow` (Unlicense, 2016): unrelated.
- No agent files, no docs on Audio Hijack or Loopback internals. The product is closed source. Nothing to learn or reuse beyond a historical reference. Their public developer posts (blog) were not searched: NOT VERIFIED.

## 5. Recommendations (at most 6, not already in the three research files)

1. **`AGENTS.md` and `docs/`: a "main thread" rule from AltTab.** Add 3 lines under Concurrency: AppKit responders are main-thread only; a latency path does visible work first; use a `MainThreadStall`-style log in debug to name a slow main-thread call. Why: budget misses on the timeline. Risk: low. Write our own text (GPL-3.0).
2. **Comment rule from AltTab, and a `rework-comments` pass.** In `AGENTS.md` Communication, add: comments say what the code cannot show (OS behavior, measured time, invariant, why a guard stays); no history; one rule once. Why: STE comments exist but no rule on what to comment; this prevents drift. Risk: low. A skill is optional; start with one `deslop` bullet.
3. **`docs/agent-editing.md`: a contract for an agent that edits a `.dirigible` package** (Compositor `writing-comp-files.md`). Content: layout, load rules, how to write safely, the `dirigible` CLI commands first, a format-version rule. Why: parity with our CLI; the product can then be driven by an agent. Risk: low; keep it a short page and check the examples in `make check-docs` (a code block that runs). Live reload of an open session is a separate feature: do not start it.
4. **Performance doc template from Compositor `brush-performance.md`.** In `docs/` (or the `performance-criteria.md` reference), a measured result lists machine, size, build configuration, median and p95, a "Reproduce" command, the gate variable, and "run alone". Why: it matches 0022; our results sit in run notes. Risk: low.
5. **Offline-render snapshot of audio in slow tests** (AudioSnapshotTesting idea, our own code). One helper writes the waveform and spectrum of a processed buffer to a PNG in `.scratchpads/` for a human or `verify-this` to read; assertions stay numeric with a tolerance. Why: a failed level or noise-reduction test then shows the shape, not only a number. Risk: medium; image output is for reading, never the assertion, because pixels vary by OS. No dependency.
6. **Read AudioCap before the process-tap slice** (R2). Add its URL to the research file for that slice (BSD-2-Clause; a pattern, no copy without a decision record). Why: Apple documents the API poorly; our probe-first rule works better with a known-good sample. Risk: none.

7. **Path-scoped rules instead of one long `AGENTS.md`** (TablePro `.claude/rules/*.md` with `paths:` front matter). Move the Concurrency and Audio-callback rules and the timeline rules to `.claude/rules/audio-realtime.md` and `timeline.md`, loaded only on a touch of `Sources/Capture` or the timeline. Keep a 2-line pointer in `AGENTS.md`. Why: lower load cost for every run. Risk: medium; Claude Code loads these, other harnesses (Codex) may not, so keep the pointer, and keep the real-time rule in `AGENTS.md` itself until a check proves the load. (Over the stated limit of 6 because the user asked for the scan; drop it if context-engineering review says no.)

Rejected: Waveform and Sparkle (no need now), AudioKit MD5 tests (brittle), IceCubes ViewModel and isolation rules (clash with decision 0013), CI workflows, Rogue Amoeba (nothing public).

## Sources

- https://github.com/robbietilton/Compositor: `AGENTS.md`, `docs/brush-performance.md`, `docs/writing-comp-files.md` (first 30 lines), `.github/workflows/verify.yml`, `scripts/` and `CompositorTests` listings, `README.md`, `project.pbxproj` settings.
- https://github.com/Dimillian/IceCubesApp: `CLAUDE.md`, `Packages/Timeline/Package.swift`, `.swiftformat`, `.github` and `scripts` listings.
- https://github.com/lwouis/alt-tab-macos: `AGENTS.md` (read), `.claude/skills` and `ai/` listings.
- https://github.com/Ranchero-Software/NetNewsWire: `CLAUDE.md` (first 30 lines).
- https://github.com/AudioKit/AudioKit `CLAUDE.md`; https://github.com/AudioKit/AudioSnapshotTesting README; https://github.com/AudioKit/Waveform README and file list; org repo list; licence and root listings of AudioKitEX, SoundpipeAudioKit, AudioKitUI, DevoloopAudioKit, Cookbook, Flow.
- https://github.com/insidegui/AudioCap README.
- https://github.com/rogueamoeba (org repo list via `gh api`).
- Root listings, licences (`gh api`) of CodeEdit, Ice, Loop, Whisky, Sparkle, IINA, Stats, Maccy, CotEditor.
- Transcript `~/.claude/projects/-Users-bquepab-projects-audio-sw-for-delineas/7c81479a-...jsonl` (user message naming Compositor).
