# Diagnostics for a hang at record start: research and design

Date: 2026-10-16

Question: what local diagnostics can Dirigible collect, so that the next hang report from a tester comes with data? Constraints: an ad-hoc signed DMG, no developer account, no notarization, macOS 14 and later, no sandbox entitlement, and no hardened runtime (`scripts/sign-app.sh` signs with `--sign -` and no `--options runtime`). No data leaves the Mac unless the user sends a file.

Context: run `2026-10-15-record-start-hang`. A tester pressed Record while Zoom had a call. The window showed the busy cursor. The tester did a force quit. The recovery kept the audio. The team had no log and no spin report, so the hypotheses H1 to H5 of that run have no field data.

Probes ran on one Mac: macOS 15.8.1 (24H32), x86_64, the user is an admin. Each probe is in **Probes run**.

## Summary

Recommendation: write an app journal file of our own, and build a support file from it by hand.

1. **A journal file for each launch** in `~/Library/Logs/Dirigible/`. One `DiagnosticLog` call writes the line to `Logger` (the live channel for Console and `log stream`) and to the journal. A serial queue writes each line with `write(2)`. The journal is the only channel that a standard user can read back after a force quit (see **What follows**).
2. **A main-thread watchdog** on its own queue. It pings the main queue each 250 ms. It writes a journal line when a ping is 1 s late, and the take step that is in progress. At 2 s it runs `/usr/bin/sample` on the app once per hang.
3. **Help > Collect Diagnostics...** and **`dirigible diagnostics collect <zip>`** build one zip from the same library function: the journals, the hang samples, the system reports that the user can read, the device list, and a summary. A redaction step removes the home path, the user name, the host name, package names, and device UIDs. The user sends the file by hand.

Run `2026-10-16-diagnostics` changed two points of this design with probes: the journal is the one sink (no `Logger` line but a journal that cannot open), and the watchdog walks the main thread in the process in place of `sample` (see **Answers of run 2026-10-16-diagnostics**).

Main limits: a standard user cannot read the system log of a previous launch or the system hang reports. `sample` suspends the process, also the audio IO thread. MetricKit delivery to an ad-hoc signed app is not proven.

## 1. What Apple gives an app with no developer account

### 1.1 os_log and Logger

- `Logger(subsystem:category:)` is the Swift API on macOS 11 and later. Apple tells you to use reverse-DNS for the subsystem, and a category for each component [A1]. Dirigible already uses the subsystem `com.delineas.dirigible` with the categories `agent-log`, `timeline`, `active-recordings`, and `agents` (`rg -n 'Logger\(' Sources`).
- Apple DTS advice: one subsystem with several categories, so a search on the subsystem shows all of the app. "One is fine, ten is OK, 100 is too much" for subsystem and category pairs [A2].
- Levels and storage [A1]:

| Level | Written to disk by default |
|---|---|
| Debug | No |
| Info | Only when the `log` tool collects it. The system also writes the memory buffer to disk when a fault occurs, and optionally an error [A3]. |
| Notice (default) | Yes, up to a storage limit |
| Error | Yes, up to a storage limit |
| Fault | Yes, up to a storage limit |

- When the store is full, the system purges the oldest messages [A1]. A debug message costs little because it stays in memory. A fault costs more [A1]. A disabled log point "has a very low cost" [A2].
- A message has a 1024-byte encoded size limit. `Enable-Oversize-Messages` raises it to 32 KB, but such messages are expensive and must not come from the main thread (`man 5 os_log`, [A4]).
- **Privacy.** By default the system does not redact integer, floating-point, and Boolean values. It redacts dynamic strings and complex objects [A1]. The options are `.public`, `.private`, `.sensitive`, and the masks `private(mask: .hash)` and similar [A5]. The hash value "is unique for the current process" [A1], so a hash does not link a value across two launches.
- **Private data on.** An `OSLogPreferences` dictionary in `Info.plist` can set `Enable-Private-Data`, and the `Enable` and `Persist` level of a subsystem or category, with no admin step (`man 5 os_log` [A4]; DTS [A6]). DTS warns: "Do not enable the recording of private data on a system you care about" [A6]. Inference: `Persist: Info` for our subsystem helps only a reader who can read the system log, which is an admin (see 1.2).
- **Export by the user.** `log collect --last <n>` writes a `.logarchive` [A7]. DTS shows it with `sudo` [A2]. Probe P1: `log collect --last 1m` ran with no `sudo` for an admin user and wrote 204 MB. A system-wide archive is too large to send, and it holds the private data of every process on the Mac. A sysdiagnose also holds a log snapshot, and DTS warns that it "might contain private information" [A8].

### 1.2 Reading the log back: OSLogStore and the log tool

- `OSLogStore(scope:)` is on macOS 12 and later, with the scopes `.currentProcessIdentifier` and `.system` (`.system` is macOS only) [A9].
- `.currentProcessIdentifier` gives only the entries of the current process. The DTS text says this for iOS. Inference for macOS: the scope has the same name and the same macOS 12 availability, and a developer report says it returns only the current run [A11] (secondary). Not checked by a probe. DTS: this "is annoying if, say, the app crashed and you want to know what it was doing before the crash", and the request for all the entries of an app is bug r. 57880434 [A2]. DTS also lists two bugs of this scope: `.reverse` does not work, and `getEntries` ignores its position [A2].
- `OSLogStore.local()` needs "an admin account" and the `com.apple.logging.local-store` entitlement [A10]. Inference: Apple gives that entitlement to no third-party app, and an ad-hoc signature cannot carry a restricted entitlement. Not checked against an Apple statement.
- `.system`: a developer reports that it works only with the App Sandbox off. DTS answers that full system log access for a sandboxed app is "a non-starter" [A11]. That thread does not cover a standard user. DTS on a log export after a crash: "You can't do this programmatically", and asks for a sysdiagnose [A12].
- Console: a user who is not an administrator must "enter an administrator name and password to search for and view log messages" [A13].
- `log show --predicate 'subsystem == "com.delineas.dirigible"'` ran with no `sudo` for an admin user and listed the app lines of the last 3 days (probe P1). For a standard user it was not tested (open question Q1).

### 1.3 MetricKit

- `MXMetricManager`, `MXDiagnosticPayload`, and `MXHangDiagnostic` are on macOS 12 and later [A14]. Diagnostic reports "arrive immediately" on macOS 12 and later. Daily metric reports arrive only on macOS 26 and later [A14]. A hang diagnostic has `hangDuration` and a `callStackTree` [A14].
- Apple: "When the main thread is unresponsive for 1 s or longer, the system also samples the app", and the reports go to Apple only "for users who consent to share data with app developers". Xcode Organizer counts a hang from 250 ms [A15]. Organizer hang reports are only for iOS and iPadOS [A15].
- No primary source says whether MetricKit delivers a payload to an ad-hoc signed app outside the App Store, or whether it needs the "share with app developers" setting on macOS (open question Q2). One developer saw no payload under Xcode and payloads after a TestFlight install [A16]. That is one report, not a rule. A MetricKit hang diagnostic for a hang that ends in a force quit is also not documented.
- Sentry tells users to move to its MetricKit integration [A17].

### 1.4 System hang, spin, and resource reports

- `spindump` makes a report "when an unresponsive application is force quit", in `/Library/Logs/DiagnosticReports/`, and shows a dialog to send it to Apple (`man spindump` [A18]).
- Console lists Crash Reports (`.ips`), Spin Reports (`.spin`), Log Reports, and Diagnostic Reports (`.diag`). An administrator can view all reports. Another user "can only view user reports" [A19]. No `.spin` or `.hang` file for Dirigible is on this Mac, so the file name of a force-quit report is not seen (open question Q3).
- `/Library/Logs/DiagnosticReports` is `root:_analyticsusers`, mode `drwxrwx---`. The group `_analyticsusers` has the `admin` group as its nested group (probe P3). So a standard user cannot read the system reports. `~/Library/Logs/DiagnosticReports` is the user folder (`.ips` crash reports).
- The system already writes resource reports for Dirigible (probe P3): `Dirigible_<date>_<host>.diag` with `Event: disk writes` (3393 s of writes in one take of v0.3.10) and `.cpu_resource.diag` with `Event: cpu usage`. Each report replaces the home folder with `/Users/USER/*` but keeps the host name in its file name.

### 1.5 What follows

After a force quit by a standard user, no Apple channel gives the app its own log of the previous launch:

- `.currentProcessIdentifier` covers only the current launch [A2] (iOS text; Inference for macOS, see 1.2).
- `.system`, Console, and `/Library/Logs/DiagnosticReports` need an admin [A11] [A13] [A19] (probe P3).
- `.local()` needs an entitlement that we cannot get [A10].

So the design needs a file that the app writes in the user domain. `man 2 fsync` says that modified data stays in "in-core modified copies of buffers" until `fsync` moves it to the disk, and that a power loss or an OS crash can lose it [A33]. Inference: the kernel owns those buffers, not the process, so a SIGKILL after `write(2)` returns keeps the line, and only a power loss or an OS crash loses it. Not checked by a probe. The system log and the system reports become extras that the bundle adds when it can read them.

## 2. A main-thread hang watchdog

- Sentry (`SentryANRTrackerV1.swift`, commit `fc3ad9f2` [A20]): a dedicated thread `io.sentry.app-hang-tracker` sleeps for `timeout / 5`, then posts a block to the main queue that sets a tick counter to 0. After 5 ticks with no reset, it reports a hang. If the sleep ends later than `timeout` past its deadline, it ignores the tick, because "a suspended app can wake much later than expected". The default timeout is 2 s [A17].
- Sentry docs: system permission dialogs can give false hangs, so Sentry has `pauseAppHangTracking()` [A17]. Since 8.50.0, a force quit during a hang shows as a "fatal app hang" on the next start [A17]. Ableton Live has the same idea: a `Log.txt` with no `Exit: End` line before the next start marks a crash [A23].
- Clock: `SuspendingClock` and `mach_absolute_time` stop while the system is asleep. `ContinuousClock` does not stop [A21]. With `SuspendingClock`, a system sleep does not look like a hang.
- Cost: each timer wake costs energy. Apple asks for a tolerance of at least 10 percent of the interval [A22]. A 250 ms timer with 25 ms leeway is 4 wakes per second, and 4 main-queue blocks that each store one value. For comparison, each device writer already runs a 50 ms drain timer during a take, which is 20 wakes per second (decision 0013 **Owners**). Inference: the watchdog adds less than one writer. Measure in the run with `top -stats pid,idlew` before and after.
- Stack capture: `sample` "suspends the process at specified intervals (by default, every 1 millisecond), records the call stacks of all threads" (`man sample` [A24]). Probe P2: `sample <pid> 1` ran with no `sudo` on an ad-hoc signed, not hardened process, and took 3 s of wall time. Its output names the main thread (`DispatchQueue_1: com.apple.main-thread`) and writes the path as `/Users/USER/*`. A hardened runtime would block it (Inference, not checked). Risk: the suspend also stops the audio IO thread of a take in progress. The run must probe this (open question Q4).
- Real-time rule (`CODING_STANDARDS.md` **Safety**, 0013 **Callbacks**): the watchdog never runs on the IO thread and never reads from it. It reads only values that the main queue, the writer queues, and `Studio` write.

## 3. What other audio apps do

- **Rogue Amoeba (Audio Hijack, and the same steps for SoundSource and Farrago).** Hold Option in the Help menu, then **Quit and Relaunch for Debugging**. Turn on only the logs that support asks for. The app writes a log file on the Desktop, quitting finishes it, and the user attaches it to an email [A25] [A26]. For crashes, the user opens Console > Crash Reports, finds the app, `arkaudiod`, or `coreaudiod`, compresses the `.ips` files to a zip, and sends it by email [A27]. Logs are off until support asks.
- **Audacity.** Help > Diagnostics has **Audio Device Info**, **Show Log** (discarded at quit), and **Generate Support Data**. That command shows each item with a check box, all on by default, and writes a zip plus a folder, which the user attaches to a report by hand [A28].
- **Ableton Live (secondary source, the help page returned HTTP 403).** **Get Support...** makes a "Status Report", a zip with the setup and the log since the last start. After a crash, Live makes a "Crash Report" [A23].
- **Hindenburg.** No public source found on logs or diagnostics. Release notes list crash fixes only [A29].
- **Logic Pro.** No public source found on a log export. Apple's troubleshooting page covers plug-ins, settings files, and a new user account [A30].

Pattern: the user sends one file by hand, and the vendor owns no upload. Audacity is the closest model: one command, all items on, the user can remove an item, and a zip at the end.

## 4. Privacy

What the evidence says to redact:

- **The home path and the user name.** Apple's own `sample` output and `.diag` reports write `/Users/USER/*` (probes P2 and P3).
- **The host name.** It is in each system report file name (`Dirigible_2026-10-15-002412_<host>.diag`), and a host name often holds the owner's name.
- **Package names and paths.** A package name is often an episode or a guest name (the tester's package was `interview-jm-oct`, `video-findings.md`). Imported file names are user names too.
- **Device UIDs.** A USB UID can hold a serial number. Replace each UID with a token (`uid-1`) that is the same in every file of one bundle, so a reader can still match a device across lines.
- **Keep device names, transport types, rates, and channel counts.** They are the diagnosis ("USB PnP Sound Device", "GroundControl Room", a Zoom virtual device). A device name with the user's name ("<name>'s AirPods") gets the user-name rule.

What the bundle never holds: audio, peaks, `session.xml`, transcripts, episode metadata, `agent-log.tsv` (it holds agent names), the list of running apps, and the system-wide log archive.

`Logger` privacy (the live channel): device names, UIDs, step names, status codes, and numbers as `.public`. Paths and package names as `.private(mask: .hash)`, following Apple's rule to redact dynamic user data [A1]. The journal keeps the raw values, because it stays on the user's Mac. The redaction runs when the bundle copies a file. Note: `ActiveRecordings.swift:37` logs a path as `.public` today.

## 5. Events to log

The take start path of `start-path.md` sets the steps. Each line has the time since the take began, in ms, from `SuspendingClock`. Levels: **notice** for a step or a state change (written to disk by default [A1]), **error** for a failure, **fault** for a broken invariant, **debug** for per-drain detail (never written to the journal).

| Category | Event | Level |
|---|---|---|
| `app` | Launch: version, build, macOS version, architecture, hardware model, locale. Quit. "The previous launch ended with no quit line", with its last line. | notice |
| `take` | Click or R key; the write chain wait ends; the playhead step; `checkTake` with the ms of each `hal.lookUp` and `hal.lookUpApp`; the microphone status; the free bytes; the `<recording>` save in ms; `begin`; each `writer.start()`; the sleep assertion; each `writer.started()` barrier; the app writers start; `handOver`; `.started` with the total ms. | notice |
| `take` | Stop request; the final drain of each writer; `finish()`; each file of the finalize; the save; the gaps of `TakeResult`; the total ms. | notice |
| `take` | A start that throws, with the `StudioError` case; `.busy`. | error |
| `device` | Each attach with its ms and `OSStatus` as a four-character code; each listener event (rate, layout, IsAlive, device-list change) with the UID and the name; lost; back; the no-record watchdog of 0013; a failed detach. | notice, or error for a failed step |
| `device` | The dropped-frame counter of each appearance, read by the drain timer at the stop and when it grows. Never from the IOProc. | notice |
| `tap` | `AudioHardwareCreateProcessTap` and `AudioHardwareCreateAggregateDevice` with ms and status; each rebuild with its cause (silence at 5 s, 15 s, 45 s, an app change, `needsRebuild`); the process count of the target app. | notice, or error |
| `permission` | The microphone status at each start and each request answer. The tap status when the System Audio Recording prompt can show. | notice |
| `disk` | The free bytes at the start, and each threshold that the 1 s check crosses (not each check). `.writeFailed` of a track. `.diskLow`. | notice, or error |
| `recovery` | At open: a pending take found, the segments recovered, the unreadable segments, the time. | notice, or error |
| `hang` | A ping 1 s late, with the take step; a sample file written; the ping arrival with the total blocked ms. | error |

Inference: with these lines, the tester's hang shows which step was open when the main thread stopped, and the sample shows whether the main thread was in a HAL frame (H1), in TCC or AVFoundation (H5), or busy in SwiftUI (H4).

## 6. Recommended design

### Modules (decision 0002)

| Target | New code |
|---|---|
| `DirigibleAudio`, new folder `Diagnostics/` | `DiagnosticLog` (one call, two sinks: `Logger` and the journal), the journal writer, `HangWatchdog`, the take step value that the watchdog reads, the bundle builder, and the redaction. |
| `DirigibleApp` | Help > **Collect Diagnostics...**, the sheet, the save panel, the `.lproj` strings (decision 0010), and the watchdog start at launch. |
| `DirigibleCLI` | `dirigible diagnostics collect`. |
| `DirigibleMCP` | Calls `DiagnosticLog` for its `agents` lines. No new tool. |

Why `DirigibleAudio`: the events come from `Studio` and `Capture/`, the code needs `os` and `Atomics`, and the bundle reads the device list. `DirigibleCore` imports only Foundation, so it cannot hold `Logger`. A new target is the per-capability split that 0002 rejected. The change amends the 0002 **Folders** line and needs a new decision record.

`AgentLog` (`Sources/DirigibleCore/AgentLog.swift`) is a versioned TSV file inside a package, with a version line and a header. The journal copies that file shape. It does not reuse the type, because the journal belongs to the Mac, not to a package.

### The journal

- Path: `~/Library/Logs/Dirigible/<yyyy-MM-dd-HHmmss>-<app|cli>-<pid>.tsv`. The first line is the version, the second line is the header (the `AgentLog` shape).
- One serial queue owns an `O_APPEND` file descriptor and calls `write(2)` once per line. No `fsync` on each line. A `fault` line and a `hang` line call `fsync`.
- Limits: 5 MB per launch, then one `truncated` line. Keep the last 20 launch files or 50 MB. Each limit is a constant in one place.
- The watchdog writes through the same queue, never through the main actor or `Studio`. Otherwise its line is lost exactly while the main thread hangs.
- At launch, the app reads the last line of the previous file. If it is not a `quit` line, the new journal gets one `app` line that says so. No prompt in the first run.

### The watchdog

- A `DispatchSourceTimer` on its own serial queue, utility QoS, interval 250 ms, leeway 25 ms [A22]. Time from `SuspendingClock` [A21].
- Each tick: if no ping waits, post one block to `DispatchQueue.main` that stores its arrival time in an atomic. If the waiting ping is 1 s old [A15], write one `hang` error line with the take step. If it is 2 s old [A17], start `/usr/bin/sample <pid> 1 10 -file ~/Library/Logs/Dirigible/hang-<time>.txt` once per hang, at most 3 times per launch. When the ping arrives, write the total blocked ms.
- Ignore a tick that comes more than one interval past its deadline (the Sentry guard [A20]).
- The take step is an atomic integer that `Studio` and the writer queues set at each step of **Events to log**. The watchdog reads it with no main-actor hop.
- The CLI runs no watchdog: it has no UI main thread.

### Help > Collect Diagnostics...

1. A sheet lists the groups, all on: launch journals (last 7 days), hang samples, crash and hang reports, the device list, the summary. The user can turn a group off (the Audacity model [A28]).
2. A save panel asks where to put `Dirigible Diagnostics <date>.zip`. The default folder is the Desktop.
3. The library copies each file into a temporary folder through the redaction, then zips the folder with `NSFileCoordinator` and `.forUploading` [A31]. That option makes a zip of a folder with Foundation only and no child process, in place of `ditto -c -k` [A32]. The coordinator unlinks its zip when the accessor block returns [A31], so the library moves the zip to the save-panel URL inside the block.
4. The app shows the zip in Finder. The user sends it by hand.

Contents:

- `summary.txt`: the version and build, macOS, the architecture, the hardware model, the free space, the microphone status, the take state, and a list of what the bundle could not read and why ("system reports: needs an administrator").
- `devices.tsv`: the `dirigible devices` columns, plus the transport type, the default input and output, and the app routes of the open session (bundle IDs only).
- `logs/`: the journals and the `hang-*.txt` samples.
- `reports/`: `Dirigible*` files of the last 30 days from `~/Library/Logs/DiagnosticReports`, and from `/Library/Logs/DiagnosticReports` when the user can read it.
- `system-log.txt`, admin only: `log show --last 1h --predicate 'process == "Dirigible"'`, so the Core Audio and TCC lines of our process are in it. Skip it with a line in `summary.txt` when the tool refuses.

### CLI parity (decision 0011)

- `dirigible diagnostics collect <output.zip> [--days <n>] [--logs <folder>] [--reports <folder>]` calls the same library function and writes no package. The folder options default to the real folders, so `DirigibleCLITests` can pass temporary folders with no environment variable (0013 rejects test code in the product).
- Exit codes: 0 when the zip exists; 2 when the output path exists or the zip cannot be written; 64 for a usage error.
- No MCP tool: the command is not an edit (0041). An agent can run the command. The run writes this as its one line for the parity rule.

### Out of the first run

- MetricKit: subscribe and copy each `MXDiagnosticPayload` JSON into `logs/` only after probe Q2 shows a payload on an ad-hoc build.
- `OSLogPreferences`: not needed. The journal holds the info lines, and the persisted system log helps only an admin reader.
- `OSSignposter` intervals for the take steps: useful in Instruments for a developer, not for a tester.

## Probes run

| id | Command | Result |
|---|---|---|
| P1 | `log show --last 3d --predicate 'subsystem == "com.delineas.dirigible"' --style compact`, then `log collect --last 1m --output <scratch>/probe-collect.logarchive` (no `sudo`, admin user) | `log show` exit 0, lines of `timeline` and `agent-log` from `swiftpm-testing-helper`. `log collect` exit 0, "Archive successfully written", 204 MB. The archive was deleted. |
| P2 | `scripts/probe.sh --no-audio <folder> bash sample-probe.sh <folder> <folder>/dirigible` (a script of this research): an ad-hoc signed copy of `.build/debug/dirigible` running `mcp`, then `/usr/bin/sample <pid> 1 -file <folder>/sample.txt` | Exit 0, 3 s wall time, 76 KB. The main thread shows as `DispatchQueue_1: com.apple.main-thread`. `Path: /Users/USER/*/dirigible`. 0 matches of the real home path. |
| P3 | `ls -la /Library/Logs/DiagnosticReports`, `dscl . -read /Groups/_analyticsusers NestedGroups`, `dsmemberutil checkmembership`, and the headers of the `Dirigible_*.diag` files | `root:_analyticsusers drwxrwx---`. The nested group is `ABCDEFAB-CDEF-ABCD-EFAB-CDEF00000050`, the `GeneratedUID` of `admin`. Three Dirigible `.diag` reports: `disk writes` (52 s, and 3393 s) and `cpu usage` (133 s). |

## Open questions

| id | Question | How to resolve |
|---|---|---|
| Q1 | Can a standard user run `log show` for our subsystem, and `OSLogStore(scope: .system)`? | Probe in a standard test account. The design does not depend on the answer. |
| Q2 | Does MetricKit deliver an `MXDiagnosticPayload` (hang or crash) to an ad-hoc signed app on macOS 14 and 15? Does it need the share-with-developers setting? Does a hang that ends in a force quit give a payload? | Probe on an ad-hoc DMG build with a forced 3 s main-thread block, then read `pastDiagnosticPayloads` at the next launch. |
| Q3 | What is the file name and extension of the spindump report after a force quit on macOS 14 and 15 (`.spin`, `.hang`, or `.ips`)? | Force quit a blocked verify copy, then list `/Library/Logs/DiagnosticReports`. The bundle globs `Dirigible*` with any extension until then. |
| Q4 | Does `sample <pid> 1 10` during a take cause dropped frames or an IO overload? | Answered: yes (see **Answers of run 2026-10-16-diagnostics**). |
| Q5 | Does a power loss lose the last journal lines with no `fsync`? | Inference only. No probe planned: the hang case is a force quit, and the page cache survives it. |

## Answers of run 2026-10-16-diagnostics

The probes ran on one Mac: macOS 15.8.1, x86_64, an i5-8259U with 4 cores, 8 logical cores, and 16 GiB.

| id | Question | Answer |
|---|---|---|
| Q4 | Does `sample <pid> 1 10` during a take make the IO thread lose input frames? | Yes. A C IOProc on the default input stored `mSampleTime` of each call, with a `kAudioDeviceProcessorOverload` listener, 12 s for each arm. With 128-frame buffers, each of 4 sample runs lost 1404 to 1624 frames with 4 to 5 overloads. With 512-frame buffers, 1 of 4 runs lost 2320 frames (59 ms between two calls). The 4 runs with no sample lost 0 frames. So the watchdog never runs `sample`. |
| Q4b | Does a walk that suspends only the main thread keep the IOProc with no gap, and does `dladdr` name the frames? | Yes. The same IOProc, the main thread blocked 3 s in three nested functions, 100 walks 10 ms apart: 0 gaps and 0 overloads in 4 runs. The suspend was 31.5 to 40.8 us mean and 418.3 us max. `dladdr` named `__semwait_signal`, `usleep`, `hangDeepB`, `hangDeepA`, `main`, and `start` (a tail call drops the frame of its caller). |
| Q4c | Does the walk keep the IOProc with no gap from a user-interactive thread with all cores busy, while the main thread is blocked and holds a lock? | Yes. 8 spinner threads (one for each logical core) at default or user-interactive QoS, the main thread blocked 4 s while it held a mutex (in a wait for a second mutex, or in malloc and free), 128-frame buffers, two repeats of each arm: 0 gaps, 0 lost frames, 0 overloads, and 0 failed walks in 16 runs of 100 walks. The suspend was 17.3 to 24.8 us mean and 167.6 us max, with 4 to 6 frames named inside `tiny_free_no_lock` and `szone_malloc_should_clear`. A default-QoS bystander thread waited 13.8 to 136.0 ms in one step with walks and with none, so a step time cannot show the cost of a walk. |

## For the lead

- The tester's Mac can already have a spindump report of the hang, because the tester did a force quit (`man spindump` [A18]). If the tester is an admin, Console > Spin Reports or Diagnostic Reports shows it. That is the fastest data for U4 and U5 of the hang run.
- Follow-up, not this scope: the system wrote a `disk writes` resource report for one take of v0.3.10 (3393 s, probe P3). Read it before Release 4 to see whether the write rate of a take is higher than needed.

## Sources

- [A1] Apple, Generating Log Messages from Your Code: https://developer.apple.com/documentation/os/generating-log-messages-from-your-code
- [A2] Apple DTS (Quinn), Your Friend the System Log: https://developer.apple.com/forums/thread/705868
- [A3] Apple, OSLogType.info: https://developer.apple.com/documentation/os/oslogtype/info
- [A4] `man 5 os_log` on macOS 15.8.1 (the `OSLogPreferences` dictionary, `Persist`, `Enable-Private-Data`, `Enable-Oversize-Messages`); Apple, Customizing Logging Behavior While Debugging: https://developer.apple.com/documentation/os/customizing-logging-behavior-while-debugging
- [A5] Apple, OSLogPrivacy: https://developer.apple.com/documentation/os/oslogprivacy
- [A6] Apple DTS, Recording Private Data in the System Log: https://developer.apple.com/forums/thread/705810
- [A7] `man log` on macOS 15.8.1, the `collect` subcommand.
- [A8] Apple DTS, Using a Sysdiagnose Log to Debug a Hard-to-Reproduce Problem: https://developer.apple.com/forums/thread/739560
- [A9] Apple, OSLogStore and OSLogStore.Scope: https://developer.apple.com/documentation/oslog/oslogstore and https://developer.apple.com/documentation/oslog/oslogstore/scope
- [A10] Apple, OSLogStore.local(): https://developer.apple.com/documentation/oslog/oslogstore/local()
- [A11] Apple Developer Forums, Can I access system logs from Swift (DTS answer, January 2024): https://developer.apple.com/forums/thread/744806
- [A12] Apple Developer Forums, Exporting logs with OSLogStore after a crash (DTS answer, July 2023): https://developer.apple.com/forums/thread/733262
- [A13] Apple, Console User Guide, Locate a log file using Console on Mac: https://support.apple.com/guide/console/cnsl9361/mac
- [A14] Apple, MetricKit, MXMetricManager, MXDiagnosticPayload, MXHangDiagnostic: https://developer.apple.com/documentation/metrickit, https://developer.apple.com/documentation/metrickit/mxmetricmanager, https://developer.apple.com/documentation/metrickit/mxdiagnosticpayload, https://developer.apple.com/documentation/metrickit/mxhangdiagnostic
- [A15] Apple, Analyzing responsiveness issues in your shipping app: https://developer.apple.com/documentation/xcode/analyzing-responsiveness-issues-in-your-shipping-app
- [A16] getsentry/sentry-cocoa issue 1661, MetricKit MXDiagnosticPayload Integration: https://github.com/getsentry/sentry-cocoa/issues/1661
- [A17] Sentry, App Hangs for macOS: https://docs.sentry.io/platforms/apple/guides/macos/configuration/app-hangs/
- [A18] `man spindump` (spindump(8)) on macOS 15.8.1.
- [A19] Apple, Console User Guide, View reports in Console on Mac: https://support.apple.com/guide/console/cnsl664be99a/mac
- [A20] getsentry/sentry-cocoa, `Sources/Swift/Integrations/AppHangTracking/SentryANRTrackerV1.swift` at commit fc3ad9f2: https://github.com/getsentry/sentry-cocoa/blob/fc3ad9f20d38/Sources/Swift/Integrations/AppHangTracking/SentryANRTrackerV1.swift
- [A21] Apple, SuspendingClock, ContinuousClock, mach_absolute_time: https://developer.apple.com/documentation/swift/suspendingclock, https://developer.apple.com/documentation/swift/continuousclock, https://developer.apple.com/documentation/kernel/1462446-mach_absolute_time
- [A22] Apple, Energy Efficiency Guide for Mac Apps, Minimize Timer Usage: https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/Timers.html
- [A23] Ableton, How to create a Status Report (HTTP 403 to the fetch tool; facts from the search excerpt, secondary): https://help.ableton.com/hc/en-us/articles/209773605-How-to-create-a-Status-Report and Reading Ableton Live Crash Reports: https://help.ableton.com/hc/en-us/articles/5301568366354-Reading-Ableton-Live-Crash-Reports
- [A24] `man sample` on macOS 15.8.1.
- [A25] Rogue Amoeba, About Audio Hijack's Debugging window: https://rogueamoeba.com/support/knowledgebase/?showArticle=Misc-DebuggingWindow&product=Audio+Hijack
- [A26] Rogue Amoeba, Collecting debugging logs from Audio Hijack: https://rogueamoeba.com/support/knowledgebase/?showArticle=Misc-CollectingLogs&product=Audio+Hijack
- [A27] Rogue Amoeba, Collecting crash logs to help solve issues with Audio Hijack: https://rogueamoeba.com/support/knowledgebase/?showArticle=Misc-CrashLogs&product=Audio+Hijack
- [A28] Audacity Manual, Help Menu: Diagnostics: https://manual.audacityteam.org/man/help_menu_diagnostics.html
- [A29] Hindenburg, Release Notes: https://hindenburg.com/support/release-notes/hindenburg-series/ and the support site: http://support.hindenburg.com/
- [A30] Apple Support, If Logic Pro for Mac isn't working: https://support.apple.com/en-us/119881
- [A31] Apple, NSFileCoordinator.ReadingOptions.forUploading: https://developer.apple.com/documentation/foundation/nsfilecoordinator/readingoptions/foruploading
- [A32] `man ditto` on macOS 15.8.1 (`-c -k --sequesterRsrc --keepParent`).
- [A33] `man 2 fsync` on macOS 15.8.1.
- Repo: `docs/decisions/0002-module-map.md`, `docs/decisions/0011-command-line-front-end.md`, `docs/decisions/0013-live-capture.md`, `Sources/DirigibleCore/AgentLog.swift`, `scripts/sign-app.sh`, and the analysis of run `2026-10-15-record-start-hang`.
