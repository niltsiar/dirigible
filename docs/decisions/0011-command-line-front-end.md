# 0011. Command-line front end: `dirigible`, built on swift-argument-parser

- Status: accepted
- Date: 2026-09-24
- Amended: 2026-09-24. `take finalize` adds exit code 3, and the edit commands take the package lock (see 0012).
- Amended: 2026-09-24. The commands `devices` and `record`, exit codes 4 (the disk is almost full) and 5 (a track has a gap or no clip of the take), and the gap lines (see 0013).
- Amended: 2026-09-24. No command meters inputs, and `devices` has no watch mode: the monitor writes nothing to a package, and `record` drives the same path (see 0015).
- Amended: 2026-09-24. `dirigible render` writes the mix as a 32-bit float stereo CAF and refuses an output path that exists (exit 2). `info` shows the media state of each file (JSON key `media`) (see 0016).
- Amended: 2026-09-25. `dirigible peaks` reads the peak cache of each pool file and writes nothing (see 0017).
- Amended: 2026-09-25. `clip paste`, `clip split-at`, and `clip nudge`, and a repeatable `--track` on `clip clear`. Show Clips in Finder has no command: it writes nothing, and `info` lists the pool paths (see 0018).
- Amended: 2026-09-25. `dirigible export` writes WAV, AAC, or FLAC. `dirigible render` calls the same writer and keeps its text and exit codes; a full disk gives "the disk is full" (see 0019).
- Amended: 2026-09-26. `dirigible capture place` puts one unplaced segment on the timeline: exit 1 for a refused placement, 2 for a package fault or a pending take, 64 for a stem that does not parse or a negative `--at`. `take finalize --leave-unreadable` ends a take without its unreadable segments; without the flag, that error names the flag (see 0021).
- Amended: 2026-10-03, run 8a. `dirigible loudness` prints the integrated loudness of each clip with its clip gain. It writes nothing and takes no lock (see 0008).
- Amended: 2026-10-04, run 12. `clip ripple-delete`, `clip ripple-insert`, and `clip ripple-trim` ripple all tracks, or the `--track` tracks. A split take exits 3 (see 0037).
- Amended: 2026-10-05, run `2026-10-05-clip-set-clipboard`. `clip paste-clips` copies whole clips with their time and track offsets and pastes them at `--at` (see 0038).
- Amended: 2026-10-07, run 2026-10-07-mcp-cli. `dirigible mcp` serves each edit command as an MCP tool, with the English text of the command. `ParityTests` also checks that each command has its tool (see 0041).
- Amended: 2026-10-08, run 2026-10-08-cli-bundle. The app bundle holds the tool at `Contents/Helpers/dirigible`, so a DMG user has `dirigible` and `dirigible mcp` with no developer setup.
- Amended: 2026-10-10, run `2026-10-10-agents-md-restructure`. **CLI parity** holds the parity rule. `AGENTS.md` points here.
- Amended: 2026-10-13, run `2026-10-13-agent-onboarding`. The root flag `--instructions` prints the agent manual, and `skill show` and `skill path` give its skill. They read no package, so they have no MCP tool (see 0051).
- Amended: 2026-10-13, run `2026-10-13-ripple-ranges`. `clip ripple-delete` takes `--from` and `--to` more than once, paired by order, and cuts all the ranges in one save. No range, or a count of `--to` that is not the count of `--from`, exits 64. The tool `clip_ripple_delete` takes `from` and `to` as arrays (see 0037).
- Amended: 2026-10-14, run `2026-10-13-transcript-1` (see 0055). `transcript import`, `transcript words`, and `transcript cut`. `transcript import` reads stdin with `-`. A file that is not a transcript exits 1. A malformed word occurrence exits 64.
- Amended: 2026-10-17, run `2026-10-17-agent-pack`. `clip heal` joins touching pieces of one file (exit 1 when no join heals). `chapters import` reads a Podcasting 2.0 chapters file. `chapters export` writes a `.txt` list. `info --json --compact` writes a short JSON. `import` has `--id`, `--offset`, `--length`, `--db`, `--fade-in`, and `--fade-out`. Each has a tool and a `ParityTests` entry.
- Amended: 2026-10-17, run `2026-10-16-diagnostics` (see 0059). `dirigible diagnostics collect <zip>` saves a redacted problem report. It reads no package and changes none, so it has no MCP tool (see 0041). Exit codes 0, 2 (the zip exists or cannot be written), and 64.
- Amended: 2026-10-19, run `2026-10-18-envelope-ducking` (see 0060). `clip envelope` sets the gain points of a clip inside the clip in timeline frames and keeps the points outside it; `--clear` removes the points inside. `clip gain-range` adds a gain to a frame range of tracks, with ramps outside the range, and writes the ID of each changed clip. A frame outside the clip exits 1; a point that does not parse exits 64. `info` shows the points. Each has a tool and a `ParityTests` entry.
- Amended: 2026-10-22, run `2026-10-18-envelope-ducking` (see 0060). `track role <package> <track> <dialogue|music|effects|none>` sets or removes the role of a track; another word exits 64, and an unknown track exits 1. `info` and `info --json` show the role. The tool `track_role` has a `ParityTests` entry.
- Amended: 2026-10-22, run `2026-10-18-envelope-ducking` (see 0060). `duck <package> [--speech <t>]... [--music <t>]... [--from <f> --to <f>] [--depth --attack --release --threshold --hold]` and the `duck` tool lower the music under the speech. A bad argument exits 64; no speech track, no track to duck, a track in both lists, or no speech over the threshold exits 1 and changes nothing.
- Amended: 2026-10-22, run `2026-10-22-take-sync` (see 0061). `take map <package> <frame>... [--take <n>] [--timeline] [--track <id>]... [--json]` maps take frames to timeline frames, or the reverse with `--timeline`. No `--take` with two takes with audio or more, or a frame under 0, exits 64; no take audio, a take with no audio, or an unknown track exits 1; a take anchor that does not read exits 2. `info` writes one `sync` line for each take with audio, or the anchor fault line, and `info --json` has `takeSync` or `takeSyncFault`. The tool `take_map` covers the command.

## Context

The user asked for a command-line front end over the same libraries as the app (2026-09-24). It has three purposes:

1. Prove that no logic sits in the SwiftUI app target. A second front end can use only the public API of the libraries.
2. Give agents an end-to-end test and verify surface. The **verify-this** skill can make, change, and read real session packages through it.
3. Let a user write scripts.

Today only `DirigibleCore` exists (0002). Its public API is the edits of `Session`, `History`, and the session file read and write (0003). The capture and export runs add `record` and `export` later.

Two facts from a prototype on 2026-09-24 (Swift 6.2.4, Intel Mac, APFS) shape the decision:

- SwiftPM writes each executable product to one folder, for example `.build/debug/`. The default APFS volume ignores case. A product `dirigible` and the app product `Dirigible` write the same file, and the last link wins. The prototype showed one binary after the build.
- A test target that depends on an executable target makes `swift test` build that executable. A test finds it next to its `.xctest` bundle with `Bundle(for:)` on a class in the test target. `Bundle.allBundles` does not find the bundle under Swift Testing. One launch of the debug binary takes about 15 ms.

## Decision

**Names.** The executable target is `DirigibleCLI` in `Sources/DirigibleCLI/`. Its product, and the command, is `dirigible`. The app target changes its name from `Dirigible` to `DirigibleApp`, so the two binaries do not clash. `scripts/bundle.sh` copies the `DirigibleApp` binary to `Contents/MacOS/Dirigible`, so the bundle, `CFBundleExecutable`, and the process name do not change.

**Grammar.** `dirigible <noun> <verb> <package> [arguments]`. The nouns follow the library: `track`, `file`, `capture`, `clip`, `marker`. `create` and `info` have no noun. Each edit command reads the package, applies one `Session` edit, and saves with `Session.write(to:)`. There is no undo across commands. A command that makes an object writes its ID and a newline to stdout. The other edit commands write nothing when they succeed. `info` writes a text summary, and `info --json` writes a JSON view of the session. Every numeric option (frames, gains, host time, rates, latency) parses with `.unconditional`, so a negative value reaches the value check or `Session` and does not become a usage error. A name, ID, or path that starts with `-` needs `--` before it, the plain swift-argument-parser rule.

**Pending take.** An edit command refuses a package whose `session.xml` holds `<recording>` (0004): exit 2, `Error: <path> has a take that is not finalized; open it in Dirigible first.` `session.xml` does not change. `info` reads the package without this check, because it never writes. This keeps the 0004 rule that only Studio writes a package with `<recording>`. A lock file for the wider case, a package the app has open without a pending take, is out of scope; it goes to the capture-run backlog.

**The executable stays thin.** `DirigibleCLI` parses arguments into domain types, calls the public API, and prints. When a command needs logic that the library does not have, the logic goes into a library in the same run. There is no command library between the CLI and `Session`: each command calls one `Session` edit, and a `Command` enum would repeat that API case by case.

**Argument parsing.** Use `apple/swift-argument-parser` (product `ArgumentParser`) in `DirigibleCLI` only.

- License: Apache-2.0, the same as this repository. Apple maintains it. SwiftPM, swift-format, and DocC use it.
- Version: `from: "1.8.0"`. The prototype resolved 1.8.2. `Package.resolved` goes into git, so each clone builds the same version.
- It gives typed options, help for each command, usage errors with exit code 64, and shell completion scripts. A hand-written parser for about 20 commands needs the same features and their tests.

**Exit codes.** Scripts and tests depend on them.

| Code | Meaning |
|---|---|
| 0 | The command succeeded. |
| 1 | The session refused the edit (`SessionError`). The package does not change. |
| 2 | The package cannot be read, written, or made (`SessionFileError`, `create` on a path that exists, or an edit command on a package with a pending take). |
| 3 | The command succeeded, but captured audio is not on the timeline (take finalize). |
| 64 | Usage error: the arguments do not parse, or a value cannot become a domain type. The package does not change. |

**CLI parity.** Each new public library feature that operates on a session package or an audio file (an edit, an import, a render, or an export) gets a `dirigible` command, an MCP tool for an edit (0041), and a `DirigibleCLITests` test in the same run. Another public feature gets one line in its run that says why it has no command. The CLI only parses, calls the library, and prints.

**Errors.** Library errors stay enums (0002). The CLI maps each case of `SessionError` and `SessionFileError` to one English line, `Error: <message>`, on stderr. The switch has no `default`, so a new error case does not compile until it has a message.

**Language.** The CLI text is English only. This is an exception to the localized UI rule of 0010. The CLI is a developer and agent tool, not a part of the app UI (R13). Scripts and agents compare its output, so the text must not change with the macOS language. The usage and help text that swift-argument-parser makes is English only, so a Spanish CLI would be half translated.

**In the app bundle.** `make app` also builds the `dirigible` product and copies it to `Contents/Helpers/dirigible`, not to `Contents/MacOS`: `dirigible` and `Dirigible` are one file on a volume that ignores case. `scripts/sign-app.sh` signs it with the identifier `com.delineas.dirigible.cli` before it signs the app. Each `make app` also builds swift-argument-parser universal, and the bundle grows by about 12 MB. The app does not call the tool.

**Tests.** The test target `DirigibleCLITests` depends on `DirigibleCLI` and `DirigibleCore`. It runs the built `dirigible` binary as a `Process` on packages in a temporary folder. It checks the exit code, stdout, and stderr as literal text, and it reads the result with `Session(contentsOf:)`. The tests use no network, no microphone, and no permission prompt.

## Consequences

- `Package.swift` gets its first remote dependency. The first `swift build` needs the network or a filled `.build` cache (0005 accepted the same for swift-atomics). A clean debug build of the prototype took about 15 s, plus about 15 s for the first fetch.
- Each new edit, import, render, or export makes the CLI larger. `ParityTests` lists the public mutating methods of `DirigibleCore` and fails when one has no command, or a command has no MCP tool, and no exemption entry. **CLI parity** states the rule.
- Two `dirigible` commands that change one package at the same time can lose one of the two edits. The save is atomic, so the file stays readable. The CLI takes no lock.
- The pending-take check comes before the write, with no lock. If Studio saves `<recording>` at take start after the CLI read the package, the CLI save removes `<recording>`, and a crash then leaves the take with no clips. Studio does not exist yet. The capture run adds a package lock that Studio and `editPackage` both take, before Studio writes `<recording>`.
- The JSON view is a contract with scripts and agents. A change that removes or renames a key is a breaking change and needs a note in the pull request.
- The app target name in `0002` and `AGENTS.md` changes to `DirigibleApp`, and `0002` gets new rows for `DirigibleCLI` and `DirigibleCLITests`, with an amended line that links to this decision.

## Alternatives considered

- **A hand-written parser over `CommandLine.arguments`.** No dependency. Rejected: about 300 lines of parser, help text, and parser tests for about 20 commands, and each new command adds help text by hand. swift-argument-parser is maintained by Apple and already tested.
- **A command library** (`DirigibleCommands`, with a `Command` enum and `run(_:package:)`) and a main file of a few lines. It allows in-process tests. Rejected: each enum case forwards to one `Session` edit with the same arguments, so the library is a pass-through with one consumer. 0002 rejected a command type for undo for the same reason.
- **Another command name** (`dirigible-cli`, `dg`) with the app target name unchanged. Rejected: the name of the command is what scripts type, and a rename of the app target costs one commit.
- **Only in a clone** (`swift run dirigible`). Rejected 2026-10-08: a user of the DMG had no `dirigible` and no `dirigible mcp`.
