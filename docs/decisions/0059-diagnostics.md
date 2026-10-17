# 0059. Diagnostics: a journal for each launch and a hang watchdog

- Status: proposed
- Date: 2026-10-16

## Context

A beta tester pressed Record during a call, the window showed the busy cursor, and the tester did a force quit. The team got no log and no hang report. The app is ad-hoc signed, with no hardened runtime and no sandbox (0001, `scripts/sign-app.sh`). The research is [docs/research/diagnostics.md](../research/diagnostics.md).

- After a force quit by a standard user, no Apple channel gives the app its log of the earlier launch. `OSLogStore(scope: .currentProcessIdentifier)` holds only the current launch. `.system`, Console, and `/Library/Logs/DiagnosticReports` need an administrator. `OSLogStore.local()` needs an entitlement that an ad-hoc app cannot have.
- A line that `write(2)` wrote stays in the file after a SIGKILL of the process (probe U2 of run `2026-10-16-diagnostics`).
- `/usr/bin/sample` suspends the whole process. With a take on 128-frame buffers, each sample run made the IOProc lose 1400 to 1600 input frames, with one overload for each gap (probe Q4 of the same run, macOS 15.8.1, x86_64).

## Decision

**Journal.** One TSV file for each launch of the app, `~/Library/Logs/Dirigible/<yyyy-MM-dd-HHmmss>-app-<pid>.tsv`. The CLI writes `-cli-<pid>.tsv` only for `record`, the one command that runs the capture code. The time of the name is UTC. Line 1 is `dirigible-journal 1`. Line 2 is the header: `time`, `uptime_ms`, `thread`, `level`, `category`, `event`, then one `key=value` column for each field. A value escapes the tab, the line feed, the carriage return, and the backslash. Line 3 is `app launch` with the version, the commit, macOS, the architecture, the model, and the locale. The front end gives the version and the commit, because the library cannot read the bundle of the CLI. The levels are `notice`, `error`, and `fault`. A reader skips a line that does not parse.

- `time` is UTC with milliseconds. `uptime_ms` is the uptime of the Mac with no sleep (`CLOCK_UPTIME_RAW`). `thread` is `main`, or the label of the queue of the caller. A Dirigible queue label ends with a device UID (`Dirigible.DeviceWriter.<uid>`), so only its first two parts go to the file.
- One call, `DiagnosticLog.note`, writes the line to the journal, the one sink. The caller only takes the time and the thread. One serial utility queue owns an `O_APPEND` descriptor, makes the text, and calls `write(2)` once for each drain, with each line that waits, so a backlog on a loaded disk costs few writes. A `hang` and a `fault` line also call `fsync`.
- When the journal cannot open (a full disk, a folder with no write), `start` returns a disabled log, writes one `fault` line to the system log (`Logger`, subsystem `com.delineas.dirigible`), and never traps. The app launches and recovers a take as before.
- `start` returns the log, and the front end passes it on. A studio gets it through the `log:` parameter of `Studio.open` and `Studio.create`, the one public seam into the library, and keeps it in its capture environment. `Studio.log` gives it to the window. Before a start, and in a caller that passes none, the log is `DiagnosticLog.disabled`. A process has one owner of its log.
- A device UID is `uid-<8 hex>` and a package is `pkg-<8 hex>`: the first 8 hex characters of HMAC-SHA256 of the value, with a random salt that the first start writes to `salt` in the log folder. The start writes a temporary file with a new name, calls `fsync`, moves it with an exclusive rename (`renamex_np` with `RENAME_EXCL`), and reads `salt` back, so two starts at once use one salt. A salt of fewer than 32 bytes is written again. One device has one token in every journal of the folder. The raw value is never in a file. No line holds a track name, a track ID, a file name, or a path in the home folder.
- No line is written on an IO thread.
- Limits: a part of 4 MiB, then the part becomes `<stem>.prev.tsv` and a new part starts with the version line, the header, and the launch line: at most 8 MiB for each launch, with its newest lines. At each start: at most 20 app launches, 20 CLI launches, and 50 MiB, the oldest deleted first. The retention deletes only the journal names (`-app-` and `-cli-` launches and their `.prev.tsv` parts), never the salt or another file. A start never deletes the file of a live PID.
- `DIRIGIBLE_LOG_FOLDER` sets the folder, as `DIRIGIBLE_MCP_SOCKET` sets the agent socket. The CLI tests set it for each child process, and the app tests pass the folder to `AppDelegate`. `make test` points it at an empty folder and fails when a test writes a file there.
- The app starts the journal in `applicationWillFinishLaunching`, before the open events, and calls `quit()` in `applicationWillTerminate`; CLI `record` calls it on each return and throw path. `quit()` queues `app quit` and `fsync` behind the other lines and waits for them at most 1 s, so a clean exit has its quit line. The wait lends the QoS of its caller to the `.utility` queue (a work item wait; a semaphore wait does not), so the lines before the quit line do not drain at `.utility` under load. On a disk that does not answer, `quit()` returns after 1 s with no quit line, and the next launch reads an unclean end: a stalled disk never holds the quit of the app.
- At each app start, the journal reads the last line of the newest earlier app journal. When it is not `app quit` and its PID is not alive, the new journal writes `app previous-unclean` with the last event and its time.
- The first line of a take start is `take start-request`, with the count of armed tracks.

**Watchdog.** In the app only. `applicationWillFinishLaunching` starts it after the journal, and `applicationWillTerminate` stops it before the quit line. `HangWatchdog.start(log:)` runs on the main actor and takes the main thread there: the macOS SDK has no call that gives the main thread from another thread. The late, sleep, and burst rules are a value type, `HangRule`, with `tick(now:)` and `answered(now:)`, so its tests use set instants and no wall time.

- A `DispatchSourceTimer` on its own user-interactive queue, `Dirigible.Watchdog`, ticks each 250 ms with 25 ms leeway and posts one ping block to the main queue. The block takes the time on the main thread, and the watchdog queue writes the line, so no line goes through the main thread.
- A ping that is 1 s late writes `hang start` with `late_ms`; its answer writes `hang end` with `blocked_ms`. Before a hang start, a tick that comes more than one interval past its deadline (a system sleep, a suspended process) sends a new ping and writes nothing. After a hang start, a late tick keeps the ping, so one hang has one start and one burst. The queue is user-interactive, so a loaded Mac delays its ticks less: under the load of the full test run, a utility timer ticked late enough to look like a sleep.
- At 2 s, one burst: one `hang images` line, 10 `hang stack` lines 100 ms apart, then one `hang names` line for each distinct stack. One burst for each hang, at most 3 for each launch. `stop()` cancels the timer, stops the rule on the watchdog queue, and waits for a burst to end at its next pause, so no `hang` line comes after the quit line.
- `hang stack` has `n`, `suspend_us` (the suspend window of the walk), `status` when the walk failed, and `frames`, the raw addresses. `hang images` has `count`, `dropped` when the list is full, and `list`, with `<header>:<slide>:<UUID>` for each image. `hang names` has `stacks` (the `n` of each stack with these frames), `names` (`<symbol>+<offset>` or `?` for each frame, split by `|`), and `images` (the path of each image of the frames, with `~` for the home folder). A return address is named at the address before it, inside the call.
- The stack comes from the C target `CMainStack`. It suspends only the walked thread, reads its registers, follows the frame-pointer chain inside the stack bounds into a buffer of the caller, and resumes it. Between the suspend and the resume, only `thread_get_state` and two clock reads run. It is C because a suspended main thread can hold a lock of the Swift runtime or of malloc, and a walk that took that lock would wait for ever. The walks run on a user-interactive queue: with all 8 logical cores busy and the main thread blocked while it holds a mutex, 100 walks lost 0 input frames, and the longest suspend was 0.17 ms (probe Q4c, macOS 15.8.1, x86_64).
- On arm64 the walk masks the pc and each saved return address with `0x00007FFFFFFFFFFF` (the 47-bit user address space of macOS, as KSCrash does), not the chain pointer. An arm64e system library signs its return addresses, and `ptrauth_strip` does nothing in a plain arm64 build ([pac-mask.md](../research/pac-mask.md)).
- At its start, the watchdog registers a C callback with `_dyld_register_func_for_add_image`, once for each process. dyld calls it for each image already loaded, during the call, and later for each new image on the thread that loads it, the main thread too. The callback takes a slot of a preallocated list of 4096 with an atomic add, writes the header address, the slide, and the `LC_UUID` of the image, and sets the ready flag of the slot with a release store. It calls no dyld function, no allocator, and no lock. dyld cannot remove the callback, so an image that unloads stays in the list.
- The burst writes `hang images` from that list first (each `hang` line calls `fsync`), then the raw stacks, and names the frames with `dladdr` only after the last stack. So a main thread that hangs in dyld, which holds the dyld lock, still gives its raw stacks for `atos`.
- The watchdog never runs `sample` (Context).

**Module.** `DirigibleAudio/Diagnostics/` holds `DiagnosticLog`, the journal, `HangWatchdog`, and `HangRule` (0002 **Folders**). The C target `CMainStack` holds the walk and the image list, and `DirigibleAudio` depends on it.

## Consequences

- A force quit keeps each line that the journal queue wrote. A power loss or a kernel panic can lose the last lines, except a `hang` or `fault` line.
- The last `main` line before a `hang start` line names the step that held the main thread.
- The stack walk on arm64 uses the same code with the arm64 register macros of the SDK and the mask. The run that adds it tests on macOS 15 x86_64 only. The `hang stack` lines of a tester journal show the result on macOS 14 and on arm64.
- A false `hang` line can come from a permission prompt or a long menu track: one line with its stack.
- A long take with a storm of dropouts can rotate its start lines out of the journal. Accepted: a storm of that size is itself the finding.
- A CLI `record` that ends with Ctrl-C has no quit line: `record` has no signal handler.

## Alternatives considered

- **`Logger` only, with an `OSLogStore` export at collect time.** Rejected: the store gives the current launch only, and the hang ends in a force quit.
- **`sample` at 2 s.** Rejected by probe Q4: it makes the IOProc lose input during a take.
- **`Logger` beside the journal.** Rejected: no reader can read it without an administrator, and its privacy rule for each value adds a second format to keep true.
- **A token for each launch.** Rejected: one device gets another token in each journal, so the lead cannot join its lines.
- **A Swift `DirigibleDiagnostics` target.** Rejected: 0002 rejects a target for each capability, and `DirigibleCore` has no event that needs a line.
