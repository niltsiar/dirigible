# 0030. The owner of an app tap: the writer slot of one appearance, on the writer queue

- Status: accepted
- Date: 2026-10-02
- Accepted: 2026-10-02, after the architect synthesis and plan gates 1 and 2 of run `2026-10-02-app-sources`.
- Amends: 0006 (the process match, the rebuild in place of a live tap update, the start order, the silence rule) and 0013 (the attach and detach of an app, IsAlive of an app aggregate, the microphone status read).

## Context

R12 records an app through a process tap and one private aggregate (0006). 0013 gives each device one `DeviceWriter` for the take and one `DeviceInput` for each appearance. Five things in that path did not fit an app:

- `DeviceInput.id` is set before `hal.attach`, but the aggregate of a tap exists only after the tap.
- A device writer finds its device by UID. A tap aggregate gets a new random UID for each appearance.
- The route check throws for a missing device. A take must start for an app that does not run yet (A7).
- The writers started in no fixed order. A tap that starts before the microphone of a Bluetooth headset had no IO in 9 of 30 starts (`docs/research/process-taps.md`, [MT-ARCH]).
- 0013 makes each identity change a loss with a gap.

Probes of the run (`.scratchpads/runs/2026-10-02-app-sources/probe/results.md`):

- P10: a live set of the process list of a tap gives `!hog` in each state (no grant). So a helper that starts needs a new tap.
- P11: with `kAudioAggregateDeviceTapAutoStartKey` false, the IO runs from the start, also for an empty tap, and `AudioDeviceStart` blocks 270 to 406 ms.
- P12: no IOProc call comes after `AudioDeviceDestroyIOProcID` returns noErr (20 of 20). An aggregate destroy with a live IOProc gives up to 11 late calls.
- P13: the input buffers of a tap aggregate are the inputs of the main sub-device first, then the tap stream.

## Decision

**Owner.** The writer slot of one appearance owns the tap and its aggregate: `(input, detach, key)`. `DeviceInput` does not change. The aggregate exists before its `DeviceInput`, in the same turn of the writer queue.

**Seams.** `DeviceHAL` has four more closures, with defaults: `lookUpApp(bundleID, layout)` reads the process set, the output, and the playing flag, and makes nothing; `makeTap(found)` makes a private unmuted mixdown tap and its private aggregate (auto start false, drift compensation, the output of a matched process as the main sub-device, else the default output, UID prefix `com.delineas.dirigible.tap.`); `appName(bundleID)` reads the LaunchServices bundle name; `deviceExists(uid)` is true when the UID gives a device object of any direction. `CaptureEnvironment.tapsAvailable` is false on macOS 14.0 and 14.1.

**Identity.** An app writer has the device UID `app:<bundle ID>` and the app name from the take start. `TrackSegments.use` takes only the rate, the latency, and the layout of a new appearance, so each segment of an app keeps that identity. The app track routes the last channels of the aggregate (P13).

**Attach and detach.** All on the writer queue. Attach: `lookUpApp`, `makeTap`, the routed-channel check, `tracks.use`, the ring, `DeviceInput(id: aggregate)`, `hal.attach`. Detach: stop the IOProc, destroy the IOProc, remove the listeners, destroy the aggregate, destroy the tap. Each step runs. The detach is clean only when each step returns noErr. A failed step keeps the ring and counts toward the 8 failed detaches of 0013. The IOProc goes before the aggregate because of P12.

**Process match.** The processes of an app are each process object whose bundle ID is the app ID or starts with the app ID and a dot, or whose executable is inside the app bundle. The apps list groups processes by the same match.

**Start.** The start check reads the microphone status only when an armed track has a device route. An app route with no process taps throws `appSourcesUnavailable` before any lookup. `begin` makes every writer and starts the device writers. `startApps` waits for the first attach of each device writer, then starts each app writer, and does not wait for them. An app attach can wait while the System Audio Recording prompt shows (verify copy of the run), so no take control waits for an app writer: the hand-over waits only for the device writers, until the start deadline (0013 Start), and the disk watch reads the WAV bytes of a writer from an atomic. The stop ends every track at the time of the click: the stop time is an atomic that the drain reads, so a writer that answers late writes no record at or after it. The stop abandons each writer that never attached, for example an app writer at the prompt, and does not wait for it. One compare-exchange of `WriterLifecycle` decides between that abandon and a late attach; the late attach detaches and writes nothing, and its queue then finishes the writer. The track of an abandoned writer gets the gap `deviceLost`. The stop waits for each writer that attached until one stop deadline: the stop call plus `stopLimit` (10 s). When a writer misses it, no finalize runs: the stop throws `writerDidNotStop`, the take stays pending, and Retry Finalize waits again until its own deadline. A writer that lives keeps the package lock (0012) until its queue finishes it. A Quit does not wait for a writer that a stop left behind; the next launch recovers the pending take.

**Rebuild (slices 4 and 5 of the run).** An `AppKey` (sorted process objects, and an output UID) is the identity of an appearance. A found key has the output that a matched process reports, else none; the key of the writer slot has the main sub-device of the running aggregate. A process-list, default-output, or device-list event rebuilds the tap into a new segment only when the found set has a process that the tap lacks, or a matched process reports an output that is not that main sub-device, or the main sub-device of the slot is not in the device list (code gate 3 H1). So a default output change with no report, and a report that comes or goes for the device that the aggregate runs on, do not rebuild (code gates 1 E3 and 2 F2). After no rebuild, the slot takes only the found processes. A set that only loses processes keeps the tap. IsAlive false on the aggregate also rebuilds. A rebuild that throws makes the track lost with the 1 s retry. The silence rule rebuilds at the first warning, 10 s after it, and 40 s after it.

## Consequences

- A rebuild loses the 0.3 to 0.4 s that `AudioDeviceStart` blocks (P11), with no gap.
- One track for each app: a second armed track on the same app has a channel in use.
- The listeners of an app writer share the C proc and the `WriterBox` of the device list (0013).

## Alternatives considered

- **A separate `AppWriter`.** Rejected: a second copy of the 0013 drain, watchdog, retry, and keep policy.
- **The tap as a virtual device behind `lookUp("app:…")`.** Rejected: an opaque hashed object ID with a collision limit, and a second seam for the order tests.
- **A live update of the tap process list.** Rejected by P10 (`!hog`).
