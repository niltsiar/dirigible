# 0059. Diagnostics: a journal for each launch

- Status: proposed
- Date: 2026-10-16

## Context

A beta tester pressed Record during a call, the window showed the busy cursor, and the tester did a force quit. The team got no log and no hang report. The app is ad-hoc signed, with no hardened runtime and no sandbox (0001, `scripts/sign-app.sh`). The research is [docs/research/diagnostics.md](../research/diagnostics.md).

- After a force quit by a standard user, no Apple channel gives the app its log of the earlier launch. `OSLogStore(scope: .currentProcessIdentifier)` holds only the current launch. `.system`, Console, and `/Library/Logs/DiagnosticReports` need an administrator. `OSLogStore.local()` needs an entitlement that an ad-hoc app cannot have.
- A line that `write(2)` wrote stays in the file after a SIGKILL of the process (probe U2 of run `2026-10-16-diagnostics`).

## Decision

**Journal.** One TSV file for each launch of the app, `~/Library/Logs/Dirigible/<yyyy-MM-dd-HHmmss>-app-<pid>.tsv`. The CLI writes `-cli-<pid>.tsv` only for `record`, the one command that runs the capture code. The time of the name is UTC. Line 1 is `dirigible-journal 1`. Line 2 is the header: `time`, `uptime_ms`, `thread`, `level`, `category`, `event`, then one `key=value` column for each field. A value escapes the tab, the line feed, the carriage return, and the backslash. Line 3 is `app launch` with the version, the commit, macOS, the architecture, the model, and the locale. The front end gives the version and the commit, because the library cannot read the bundle of the CLI. The levels are `notice`, `error`, and `fault`. A reader skips a line that does not parse.

- `time` is UTC with milliseconds. `uptime_ms` is the uptime of the Mac with no sleep (`CLOCK_UPTIME_RAW`). `thread` is `main`, or the label of the queue of the caller. A Dirigible queue label ends with a device UID (`Dirigible.DeviceWriter.<uid>`), so only its first two parts go to the file.
- One call, `DiagnosticLog.note`, writes the line to the journal, the one sink. The caller only takes the time and the thread. One serial utility queue owns an `O_APPEND` descriptor, makes the text, and calls `write(2)` once for each line. A `hang` and a `fault` line also call `fsync`.
- When the journal cannot open (a full disk, a folder with no write), `start` returns a disabled log, writes one `fault` line to the system log (`Logger`, subsystem `com.delineas.dirigible`), and never traps. The app launches and recovers a take as before.
- `start` returns the log, and the front end passes it on. A studio gets it through the `log:` parameter of `Studio.open` and `Studio.create`, the one public seam into the library, and keeps it in its capture environment. `Studio.log` gives it to the window. Before a start, and in a caller that passes none, the log is `DiagnosticLog.disabled`. A process has one owner of its log.
- A device UID is `uid-<8 hex>` and a package is `pkg-<8 hex>`: the first 8 hex characters of HMAC-SHA256 of the value, with a random salt that the first start writes to `salt` in the log folder. The start writes a temporary file with a new name, calls `fsync`, moves it with an exclusive rename (`renamex_np` with `RENAME_EXCL`), and reads `salt` back, so two starts at once use one salt. A salt of fewer than 32 bytes is written again. One device has one token in every journal of the folder. The raw value is never in a file. No line holds a track name, a track ID, a file name, or a path in the home folder.
- No line is written on an IO thread.
- Limits: a part of 4 MiB, then the part becomes `<stem>.prev.tsv` and a new part starts with the version line, the header, and the launch line: at most 8 MiB for each launch, with its newest lines. At each start: at most 20 app launches, 20 CLI launches, and 50 MiB, the oldest deleted first. The retention deletes only the journal names (`-app-` and `-cli-` launches and their `.prev.tsv` parts), never the salt or another file. A start never deletes the file of a live PID.
- `DIRIGIBLE_LOG_FOLDER` sets the folder, as `DIRIGIBLE_MCP_SOCKET` sets the agent socket. The CLI tests set it for each child process, and the app tests pass the folder to `AppDelegate`. `make test` points it at an empty folder and fails when a test writes a file there.
- The app starts the journal in `applicationWillFinishLaunching`, before the open events, and calls `quit()` in `applicationWillTerminate`; CLI `record` calls it on each return and throw path. `quit()` queues `app quit` and `fsync` behind the other lines and waits for them at most 1 s, so a clean exit has its quit line. The wait lends the QoS of its caller to the `.utility` queue (a work item wait; a semaphore wait does not), so the lines before the quit line do not drain at `.utility` under load. On a disk that does not answer, `quit()` returns after 1 s with no quit line, and the next launch reads an unclean end: a stalled disk never holds the quit of the app.
- At each app start, the journal reads the last line of the newest earlier app journal. When it is not `app quit` and its PID is not alive, the new journal writes `app previous-unclean` with the last event and its time.
- The first line of a take start is `take start-request`, with the count of armed tracks.

**Module.** `DirigibleAudio/Diagnostics/` holds `DiagnosticLog` and the journal (0002 **Folders**).

## Consequences

- A force quit keeps each line that the journal queue wrote. A power loss or a kernel panic can lose the last lines, except a `hang` or `fault` line.
- A long take with a storm of dropouts can rotate its start lines out of the journal. Accepted: a storm of that size is itself the finding.
- A CLI `record` that ends with Ctrl-C has no quit line: `record` has no signal handler.

## Alternatives considered

- **`Logger` only, with an `OSLogStore` export at collect time.** Rejected: the store gives the current launch only, and the hang ends in a force quit.
- **`Logger` beside the journal.** Rejected: no reader can read it without an administrator, and its privacy rule for each value adds a second format to keep true.
- **A token for each launch.** Rejected: one device gets another token in each journal, so the lead cannot join its lines.
- **A Swift `DirigibleDiagnostics` target.** Rejected: 0002 rejects a target for each capability, and `DirigibleCore` has no event that needs a line.
