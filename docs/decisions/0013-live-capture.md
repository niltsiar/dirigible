# 0013. Live capture: C callbacks, the ring in the device writer, device events, disk and sleep

- Status: accepted
- Date: 2026-09-24

## Context

Decision 0004 fixes the capture pipeline, 0005 the ring dependency, and 0012 the files. The capture-finalize run built everything except the device side. The capture-live run (`.scratchpads/runs/2026-09-24-capture-live/`) adds the IOProcs, the rings, the device events, the disk rule, the sleep assertion, and the CLI commands. Probes on 2026-09-24 (macOS 15.7.9, x86_64, Swift 6.2.4; `probe/output.txt` of the run) changed some 0004 details:

- An IOProc block (`AudioDeviceCreateIOProcIDWithBlock`) written as a closure literal in `@MainActor` code runs on the HAL thread with no error: a silent data race. The same closure through the C API (`AudioDeviceCreateIOProcID`) stops the process with SIGILL on the first call (`dispatch_assert_queue_fail` from `swift_task_isCurrentExecutor`). This is the crash that `AGENTS.md` describes.
- A block listener (`AudioObjectAddPropertyListenerBlock`) removed from Swift returns noErr and keeps getting calls, also with a stored `@convention(block)` value. A C listener (`AudioObjectAddPropertyListener`) gets no call after its removal returns.
- A missing UID translates to noErr and device 0. A gone object gives '!obj' on property reads and listener adds, and '!dev' on IOProc create and start.
- `statfs` gives the free blocks. `volumeAvailableCapacityForImportantUsage` also counts purgeable space (2x on the test volume).
- A command-line binary can take the sleep assertion and read the microphone status with no prompt.
- On x86, a stress test of the SPSC ring and the thread sanitizer do not find a ring with relaxed order. Only review and an arm64 run can check the order.
- `AudioFileWriteBytes` on a full disk gives -40, not ENOSPC, the same status as a volume that goes away.

## Decision

**Callbacks.** The IOProc and every property listener use the C APIs: `AudioDeviceCreateIOProcID` and `AudioObjectAddPropertyListener`, each with a client-data pointer. Each callback is a `static let` C function of a nonisolated type, never a closure literal in isolated code. It captures nothing. The IOProc gets the ring context. A device listener gets its `DeviceInput` (see Owners) as an `Unmanaged` retained pointer, released only after the removal returns noErr. A `DeviceInput` holds its writer weakly, so a kept input never keeps the writer alive, and a late call after the stop does nothing. The device-list listener gets a retained box that holds the writer weakly, the same way. A listener hops to the writer queue with `queue.async`. The IOProc only copies the input buffer list and the time stamp into the ring. This replaces the block API of 0004.

**Owners.** `DeviceWriter` is the recorder of one device for the whole take: the tracks, the segments, the device state, the gaps, and one 50 ms drain timer on its serial queue. `DeviceInput` is one appearance of the device, from a successful attach to its detach: the object ID, the ring, the IOProc, and the device listeners. A device that comes back gets a new `DeviceInput` with a ring that no IOProc has reached. Every device event runs on the writer queue. There is no `Recorder`. `Studio` keeps the take-wide policy: the start order, the disk watcher, the sleep assertion, and the track states for the UI.

**Ring.** One SPSC byte ring for each appearance of a device (0005). The writer queue allocates it before the attach and writes zeros to every byte, so the IO thread never touches a new page first. Capacity: 10 s at the nominal rate at the attach x the input channels x 4 bytes, plus 25%, rounded up to a power of two, and 64 MiB or less. A rate or layout event that needs a larger ring starts a new appearance: the writer detaches and attaches again with a new ring. The IO thread never writes into a ring that grows. `head` and `tail` are monotonic byte counts in `UnsafeAtomic<Int>`: the producer loads `tail` acquiring and stores `head` releasing; the consumer loads `head` acquiring and stores `tail` releasing. A record that does not fit is dropped whole, and its frames go to an atomic dropped-frame counter. The record layout is internal and not persisted.

**Detach.** The detach stops the device, destroys the IOProc, and removes the listeners. When every call returns noErr, no IOProc call can come, and the writer frees the ring bytes. A listener call can still be in progress when its removal returns, and it uses the `DeviceInput` and the rate atomic of its ring. So the writer keeps the input and the ring atomics until `finish()` removes the device-list listener: about 200 bytes for each appearance of the take. When a call fails, a late IOProc or listener call can still come, so the writer keeps the `DeviceInput` (ring and client data) for the process life. A writer with 8 kept inputs attaches no more in that take; the device stays lost. The leak is 8 rings per device per take or less. Because each appearance has its own ring, a late call of an old appearance never writes into the ring of a new one. An `attach` that throws before its IOProc exists leaves an empty ring that no call can reach: the writer keeps it for the next try when the capacity is the same. An `attach` that throws after that, with an undo that returned noErr, is a clean detach: a listener call can still be in progress, so its ring goes to no other attach. The routed channels are checked before the allocation, and the format before the IOProc, so a retry each 1 s does not allocate a ring each time.

**Device events.** Listeners on the nominal rate, the input stream configuration, and IsAlive of each device, and on the device list of the system object:

- Each device listener posts its event with its `DeviceInput`. The writer ignores a rate, layout, or IsAlive event from an input that is not the current one, so a late call of an old appearance never acts on the current one.
- A rate change: the listener stores the new rate in the ring atomic of its appearance first, and then posts the event. The next record header has the new rate and breaks the segment (0004). When the new rate needs a larger ring, the device attaches again (see Ring). If that attach fails, the device is lost.
- A layout change ends the segment. If a routed channel is gone, the device is lost.
- IsAlive false, or a device-list change where the UID gives no object, ends the segments and detaches: the device is lost. The other devices record.
- A device-list change where the UID gives an object ID that is not the attached one: the device is lost, and it attaches again at once.
- A running device that gives no valid record for 2 s: the watchdog on the drain timer ends the segment and detaches; the device is lost. From an attach to the first valid record of that appearance, the limit is 10 s (`CaptureEnvironment.firstRecordLimit`), because a device (for example a Bluetooth headset) can need seconds to start its IO.
- A lost device tries to come back each 1 s on the drain timer, and at once on a device-list change. When the UID gives an object that is alive, with the routed channels, it attaches again. The next record opens a new segment.
- Stop cancels the drain timer after the final drain, so the watchdog and the retry end with it. An event or a tick after the stop does nothing.
- A record without valid sample and host times ends the segment. It does not restart the watchdog clock.
- `attach` refuses a stream whose virtual format is not packed float32 linear PCM; the device is lost.

**Write errors.** A write, flush, checkpoint, or open error closes the segment of that track only. After 1 s or more of device frames, the writer opens the next segment number for that track. The other tracks keep their segments. A segment number can be skipped (0012). The public state is `.writeFailed` with no cause: the status cannot tell a full disk from a gone volume (-40 for both). The disk watcher reports a full disk for the whole take (`.diskLow`).

**Gaps.** A track has a gap when it was lost or failed for part of the take or for all of it. The writer records the first gap state of each track on its queue, and `finish()` returns them. `Studio.lastTake` (`TakeResult`: the take, the end, the gaps) is set before the finalize. A report to the main actor is only for the UI, so a late report cannot hide a gap.

**Start.** `Studio.startRecording(armed:playhead:)` is `async`. The main actor does no file and no HAL work: the lookup, the status read, `statfs`, `mkdir`, and the save run off the main actor on a copy of the session, and the main actor then sets the writers and the transport. From the first check to the end of the start, an edit, a save, a second start, and a stop throw `.busy`. It runs: the idle and pending-take checks; the device lookup and the route checks; the microphone status read (`AVCaptureDevice.authorizationStatus(for: .audio)`, never a request); the disk check (less than 1 GB free throws `.diskLow`); the 0004 start order (save `<recording>`); the sleep assertion and the disk watcher; then the attach of each device. A throw before the save changes nothing. An attach failure after the save makes that device lost, with a gap, and the retry goes on; it does not end the take. The front ends request the microphone access and call again. This replaces "the app target checks" in 0004.

**Disk.** The free space is `statfs` `f_bavail * f_bsize`, read off the main actor; an errno counts as 0. Every 1 s during a take, the studio stops the take cleanly when the free space is less than the WAV bytes of the take so far plus 1 GB (0004), and the end of `lastTake` is `.diskLow`. The remaining record time before a take uses 7 bytes per sample and channel and subtracts the WAV bytes of a pending take (3 for each 4 CAF bytes).

**Sleep.** `kIOPMAssertPreventUserIdleSystemSleep`, named `Dirigible is recording`, from the start of the take until its finalize ends.

**Test seams.** One internal `CaptureEnvironment` value holds closures for the device lookup and the attach (`DeviceHAL`), the microphone status, and the free space, and the disk check interval. `live` calls the system. Tests give closures and call `CaptureRing.ioProc` from a thread with synthetic buffers. No protocol. Tests may read the real device list (read only, no prompt) and assert only invariants on it.

**CLI (0011).** `dirigible devices` writes one line per input device: `<uid>\t<name>\t<channels>\t<rate>`. `dirigible record <package> --seconds <n> --arm <track> [--arm <track> ...] [--playhead <frames>]` records a take and writes the clip ID of each placed segment. On a not-determined microphone status it requests access once. After the take, it writes one stderr line for each track in the gaps of `Studio.lastTake`, also when the finalize fails (exit 2): `Warning: track "<id>" lost its device during the take.` or `Warning: track "<id>" had a write error during the take.` It writes `Warning: track "<id>" has no clip from take <n>.` for each armed track with no clip of the take. Exit codes: 0 success; 1 the take did not start (unknown track, no route, missing device, channel out of range or in use, no microphone access, less than 1 GB free), and the package did not change; 2 a package fault (0011); 3 captured audio is not on the timeline (0012); 4 the take stopped early because the disk is almost full, and the clips are placed; 5 an armed track has a gap or no clip of the take, and the clips are placed. When more than one applies, the lowest code of 2, 3, 4, 5 wins, and each line is still written. `take finalize` uses the same rule. After a crash it knows no gaps, so it gives 5 only for an armed track with no clip of the take. It reads the armed tracks from `Studio.recoveredTake`, the `Recording` that the recovery of `Studio.open` finalized, or from the pending take before its retry.

## Consequences

- 0002: the `Recorder` row and the "Recorder is an actor" rule change to `DeviceWriter` as the recorder of one device. 0002 gets an amended line.
- 0004: the block APIs become the C APIs; the library reads the microphone status; the per-track reopen after a write error. 0004 gets an amended line.
- 0005: one ring for each appearance of a device, owned by its `DeviceInput`, which the `DeviceWriter` owns. 0005 gets an amended line.
- 0011: exit codes 4 and 5, the gap lines, and two commands. 0011 gets an amended line.
- `DirigibleAudio` depends on `Atomics` (0005) and imports IOKit for the sleep assertion.
- `InputDevice` becomes public, read only.
- A take that the user ends with Ctrl-C in `dirigible record` is a crash for the library: `dirigible take finalize` recovers it.
- The ring order has no check that can fail on x86. `CaptureRingStressTests` (2,000,000 records, behind `DIRIGIBLE_SLOW_TESTS`, so `make test-slow` runs it) is the check, and a run on arm64 is part of the run's manual checks.
- A failed detach leaks up to 8 rings per device per take, and a device that fails 8 detaches stays lost until the take ends.
- A device that pauses its IO for 2 s or more gets a new segment and a gap.
- A device that needs more than 10 s from the attach to its first valid record is lost at each attach. A device that gives only records without valid times is lost after 10 s, not 2 s.
- A rate change to a higher rate stops and starts the IO of the device. The frames of that restart are lost, in a segment break that the rate change makes anyway.
- A device with more than 64 MiB for 10 s (for example 64 channels at 768 kHz) has a ring for less than 10 s: 0.34 s at the cap, more than 6 drains.

## Alternatives considered

- **The block APIs with `@Sendable` literals.** Rejected: a block listener cannot be removed from Swift, and a block in isolated code races with no signal.
- **`-enable-actor-data-race-checks` for debug builds.** Rejected: not needed with the C callbacks, and `unsafeFlags` guard only debug builds.
- **A pure state machine with an effect interpreter for each device.** Rejected: the segment policy would split between the machine and `DeviceWriter`, and every cell would need a test in the machine and in the shell.
- **The IOProc inside `DeviceWriter` with no `DeviceInput`.** Rejected: it mixes the state of one appearance with the state of the take.
- **One ring for the whole take, kept after a failed detach.** Rejected: the next appearance would add a second producer to the ring while a late call of the old IOProc can still come.
- **A public `writeFailed` cause (disk full or other).** Rejected: the status of a full disk and of a gone volume is the same (-40).
- **Live gap lines in the CLI, from a poll of the track states.** Rejected for now: a poll can miss a short loss. The end lines come from the writer's own record.
- **`volumeAvailableCapacityForImportantUsage` for free space.** Rejected: it counts space that a write cannot use now.
- **A synthetic device behind an environment variable, for end-to-end `dirigible record` tests.** Rejected: test code in the product.
