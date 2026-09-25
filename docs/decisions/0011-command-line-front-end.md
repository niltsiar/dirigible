# 0011. Command-line front end: `dirigible`, built on swift-argument-parser

- Status: accepted
- Date: 2026-09-24
- Amended: 2026-09-24. `take finalize` adds exit code 3, and the edit commands take the package lock (see 0012).
- Amended: 2026-09-24. The commands `devices` and `record`, exit codes 4 (the disk is almost full) and 5 (a track has a gap or no clip of the take), and the gap lines (see 0013).
- Amended: 2026-09-24. No command meters inputs, and `devices` has no watch mode: the monitor writes nothing to a package, and `record` drives the same path (see 0015).
- Amended: 2026-09-24. `dirigible render` writes the mix as a 32-bit float stereo CAF and refuses an output path that exists (exit 2). `info` shows the media state of each file (JSON key `media`) (see 0016).
- Amended: 2026-09-25. `dirigible peaks` reads the peak cache of each pool file and writes nothing (see 0017).
- Amended: 2026-09-25. `clip paste`, `clip split-at`, and `clip nudge`, and a repeatable `--track` on `clip clear`. Show Clips in Finder has no command: it writes nothing, and `info` lists the pool paths (see 0018).

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

**Errors.** Library errors stay enums (0002). The CLI maps each case of `SessionError` and `SessionFileError` to one English line, `Error: <message>`, on stderr. The switch has no `default`, so a new error case does not compile until it has a message.

**Language.** The CLI text is English only. This is an exception to the Localized UI rule in `AGENTS.md`. The CLI is a developer and agent tool, not a part of the app UI (R13). Scripts and agents compare its output, so the text must not change with the macOS language. The usage and help text that swift-argument-parser makes is English only, so a Spanish CLI would be half translated.

**Not in the app bundle.** `make app` builds only the `DirigibleApp` product (`swift build --product DirigibleApp`), and the bundle holds one executable. The users of the app are podcast producers. The CLI is for developers, agents, and scripts. A second binary in the bundle adds a universal build of swift-argument-parser to every `make app`, and no user story needs it now. A developer runs `swift run dirigible` or builds it with `swift build --product dirigible`.

**Tests.** The test target `DirigibleCLITests` depends on `DirigibleCLI` and `DirigibleCore`. It runs the built `dirigible` binary as a `Process` on packages in a temporary folder. It checks the exit code, stdout, and stderr as literal text, and it reads the result with `Session(contentsOf:)`. The tests use no network, no microphone, and no permission prompt.

## Consequences

- `Package.swift` gets its first remote dependency. The first `swift build` needs the network or a filled `.build` cache (0005 accepted the same for swift-atomics). A clean debug build of the prototype took about 15 s, plus about 15 s for the first fetch.
- Each new public library feature that operates on a session package or an audio file, an edit, an import, a render, or an export, gets a `dirigible` command in the same run, with a test in `DirigibleCLITests`. A `DirigibleCLITests` test lists the public mutating methods of `Session` and fails when one has no command and no exemption entry. Another public feature gets one line in its run that says why it has no command. `AGENTS.md` states the rule.
- Two `dirigible` commands that change one package at the same time can lose one of the two edits. The save is atomic, so the file stays readable. The CLI takes no lock.
- The pending-take check comes before the write, with no lock. If Studio saves `<recording>` at take start after the CLI read the package, the CLI save removes `<recording>`, and a crash then leaves the take with no clips. Studio does not exist yet. The capture run adds a package lock that Studio and `editPackage` both take, before Studio writes `<recording>`.
- The JSON view is a contract with scripts and agents. A change that removes or renames a key is a breaking change and needs a note in the pull request.
- The app target name in `0002` and `AGENTS.md` changes to `DirigibleApp`, and `0002` gets new rows for `DirigibleCLI` and `DirigibleCLITests`, with an amended line that links to this decision.

## Alternatives considered

- **A hand-written parser over `CommandLine.arguments`.** No dependency. Rejected: about 300 lines of parser, help text, and parser tests for about 20 commands, and each new command adds help text by hand. swift-argument-parser is maintained by Apple and already tested.
- **A command library** (`DirigibleCommands`, with a `Command` enum and `run(_:package:)`) and a main file of a few lines. It allows in-process tests. Rejected: each enum case forwards to one `Session` edit with the same arguments, so the library is a pass-through with one consumer. 0002 rejected a command type for undo for the same reason.
- **Another command name** (`dirigible-cli`, `dg`) with the app target name unchanged. Rejected: the name of the command is what scripts type, and a rename of the app target costs one commit.
- **The CLI in the app bundle** (`Contents/Helpers/dirigible`). Rejected for now, for the reasons in the decision. Add it when a user needs scripts without a developer setup.
