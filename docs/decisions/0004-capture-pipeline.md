# 0004. Capture pipeline: one IOProc per device, CAF segments, recovery on open

- Status: accepted
- Date: 2026-09-24
- Amended: 2026-09-24. The file names, the sidecar bytes, the take number rule, the package lock, and the armed-track rules are in 0012. A fault of one segment leaves that segment unplaced and ends the take; only a fault that can go away keeps the take pending (0012). A clip over 4 GiB is RF64 (0012).

## Context

R3 and R4 ask for several sources at the same time, each on its own track, without an aggregate device. `AGENTS.md` asks for no data loss after a crash, an unplug, or a full disk, and for the timing data to align devices with different clocks. The evidence is in `docs/research/capture.md` and in local tests:

- A CAF writer killed with SIGKILL leaves every written second readable. A WAV writer leaves a header with 0 bytes (`.scratchpads/verify/caf-crash/`, 21.0 s of 21 s against 0 s).
- `ExtAudioFileWriteAsync` lost 0.27 s on SIGKILL. Synchronous writes lost nothing.
- `AudioDeviceCreateIOProcIDWithBlock` gives the device sample time and host time for each buffer. Process taps (0006) use the same path.

The plan gate (two rounds) added the rules for rate changes, reconnects, recovery ownership, and disk and power failures.

## Decision

**Capture.**

- The app target checks the microphone permission before it calls `Studio.startRecording`: it reads `AVCaptureDevice.authorizationStatus(for: .audio)`, requests access if it is not determined, and refuses the take with a link to the privacy settings if it is denied. This is a UI flow, so it is not in the library.
- Test seams, with no protocol. Open-path tests write the package files on disk (`session.xml` with `<recording>`, CAF files, and sidecars made by the real writer) and call `Studio.open`. Stop-path tests use an internal (`@testable`) `Studio` entry that starts a take from a device description and a prepared ring, without an IOProc, then push synthetic ring records (a sine with known timestamps).
- `startRecording` refuses a route with a channel that the device does not have (`.channelOutOfRange`), and a device channel that feeds two tracks (`.channelInUse`).
- One IOProc per input device, from `AudioDeviceCreateIOProcIDWithBlock` with a NULL queue. AUHAL is the fallback if the IOProc path fails on hardware. This replaces the "AUHAL, one input unit per device" text in 0001.
- The IOProc copies the whole input buffer list into one SPSC ring per device (0005) and does nothing else. Each ring record header holds the sample time, the host time, the frame count, `mNumberBuffers`, each `mDataByteSize`, and the nominal rate. A property listener stores the new nominal rate in an atomic, and the IOProc copies it into each header. The header rate can lag the real change by one listener delay, so it is a hint. The writer and finalize check it (see below). If the ring is full, the IOProc adds the lost frames to an atomic counter. The UI shows this counter during a take.
- Each ring holds 10 s of audio. It is allocated before the IOProc starts.
- Each device has one writer on its own serial `DispatchQueue`, never on the cooperative pool. The writer drains the ring every 50 ms and takes out the channels of each track (0002, `Track.route`). It writes one float32 CAF per track with synchronous writes.
- The writer checks each record's byte sizes against frames x channels x 4. On a mismatch, it closes the segment at that record.
- Every 5 s, the writer calls `fcntl(F_FULLFSYNC)` on each CAF and sidecar.

**Timing.**

- Each segment has a sidecar file next to it. The first record holds the capture header: device UID, device name, nominal rate, the available nominal rates of the device (`kAudioDevicePropertyAvailableNominalSampleRates`), channel count, input latency, and the host time and sample time of the first frame. After that, the writer appends a checkpoint about once per second, and one at the last record of each segment: the file frame index, the sample time, and the host time. A segment shorter than 0.5 s, or with a zero host-time span, has no usable fit and takes the "no usable checkpoint" path of finalize.
- The take anchor: timeline start = playhead at record start + (first-frame host time - take start host time) - latency. Host time never crosses a take, because host time is valid for one boot only.

**Segments.** A new segment file starts on any of these events:

- a new nominal rate or a byte size mismatch in a ring record header;
- a jump of more than 1% in the sample-time to host-time slope, measured over the last 0.5 s of records and compared with the running fit of the segment. This catches a rate change before the header rate shows it. Host-time jitter between single records does not split a segment. The new segment starts at the first record after the window. The records of the window stay in the old segment and in its fit; the bias is at most 0.5 s of audio at the new rate;
- a stream format change or IsAlive false (property listeners on each device);
- a backward jump of the sample time, or a forward jump of more than 2 s.

A forward jump of 2 s or less gets silence, and the writer logs the gap. The names are `<trackID>-<take>-<segment>.caf` and `.sidecar`.

**Device lost and back.** While a take runs, the recorder listens to `kAudioHardwarePropertyDevices`. When the UID of a lost device comes back, the recorder restarts its IOProc into a new segment. Until then, the track shows a persistent "device lost" state. The other tracks continue.

**Finalize at stop.**

- Fit a line through the checkpoints of each device segment. The slope is the real rate. Choose the rate in this order:
  1. The fit is within 1000 ppm of the header rate: use the fit.
  2. Otherwise, the fit is within 1000 ppm of a discrete available nominal rate of the device (an `AudioValueRange` with min equal to max, from the sidecar header): the header rate lagged, so snap to that rate. A continuous range (min less than max) is not a snap target.
  3. Otherwise, the fit is not trusted: convert from the header rate, set `driftCorrected="false"`, and give the clip a warning mark.
- Tests cover a 24 kHz segment with a correct header rate (rule 1), a segment with a lagged header rate made by the real writer (rule 2), a bad fit on a device with a continuous range (rule 3), and a long synthetic take with host-time jitter that stays one segment.
- Discard a torn last sidecar record. A segment with no usable checkpoint goes on the timeline from its first record at the header rate, with a warning mark.
- Always write a 24-bit WAV at the session rate (0003) with `AudioConverter`. Resample when the source rate differs from the session rate. The source rate is:
  - under rule 1 or 2: the nominal rate (the header rate, or the snapped rate of rule 2), or the fitted rate when the drift over the segment at the nominal rate is more than 1 ms;
  - under rule 3, or with no usable checkpoint: always the header rate.
- Store `resampledFromRate` in the `<capture>` element whenever finalize resampled, under any rule. `resampledFromRate` and `driftCorrected="false"` can be on the same `<capture>`.
- Finalize is deterministic: the clip IDs and the WAV paths come from the take and segment identity. A take number is never reused in a package: the next take number is the highest take number in the CAF and WAV file names of the package, plus one. A second run of finalize on the same take overwrites the output of the first.
- Release 1 keeps every raw CAF until the hardware drift spike confirms the fit. A later run deletes a CAF only after its WAV passes the frame-count check.
- The player and the export never read a CAF.

**Recovery has one owner: `Studio.open`.**

- The `<recording>` element in `session.xml` (0003) is the single source of truth. An active-recordings list in Application Support is only a hint that tells the app which sessions to reopen at launch.
- Start order: (1) delete any `recovery-attempt` marker, then save `session.xml` atomically with the new tracks and the `<recording>` element; (2) add the session URL to the list; (3) start the IOProcs. A crash between (1) and (2): the app does not reopen the session at launch, but the next open recovers it.
- Stop order: (1) finalize; (2) save `session.xml` atomically with the clips and without `<recording>`; (3) remove the URL from the list. A crash between (2) and (3): open finds no `<recording>` and removes the stale entry.
- `Studio.open` is `async`. It reads `session.xml` off the main actor. If `<recording>` is absent, it deletes a leftover `recovery-attempt` marker and opens normally. If `<recording>` is present and no marker exists, it writes the `recovery-attempt` marker file in the package, runs finalize on the segment files it finds, removes the marker, saves, and then returns the studio. Every finalize that succeeds (at stop, at open, or in a retry) removes the marker before the save that removes `<recording>`. A crash between the marker removal and the save looks like a recovery not yet tried, which is safe to run again.
- If `<recording>` and the marker are both present, the process died during an earlier recovery. Open skips finalize and returns the studio with a pending take. So a recovery that crashes the app cannot crash every launch or every open. Recovery is idempotent. Nothing else writes `session.xml` during recovery.
- If finalize throws, at stop or at open, for example on a full disk, it removes the marker, the `<recording>` element stays, and the studio has a pending take. The CAF files stay untouched. The marker stays only when the process dies.

**Studio state.** The transport state is `idle`, `playing`, `recording(Take)`, or `finalizing(Take)`. The state stays `finalizing` until stop step (2) completes or finalize fails. In Release 1, an edit, an undo, a save, or a new take throws `.busy` in `recording` and `finalizing`. Stop records one History entry.

**Pending take.** `pendingTake: Take?` is separate from the transport state, because `<recording>` in `session.xml` already stores it. Play and stop do not clear it.

- While `pendingTake` is set, these actions throw `.busy`: a new take; delete, a route change, or a layout change of a track of the take; an undo that removes a track of the take or changes its route or layout. Every save writes `<recording>` back.
- The studio tells the user how much free space finalize needs. When the user asks, it runs finalize again in the `finalizing` state, so edits, undo, and save throw `.busy` during the retry. A retry that succeeds clears `pendingTake`.
- The remaining-record-time display (see "Disk and sleep") subtracts the space that the pending finalize needs.

**Disk and sleep.**

- A take needs 7 bytes per sample and channel on disk: 4 for the float32 CAF and 3 for the 24-bit WAV, because Release 1 keeps the CAF. The rate of use is the sum over the armed tracks of channels x rate x 7 bytes per second.
- Before a take, show the remaining record time from the free space and that rate. During a take, stop cleanly and tell the user when the free space is less than the WAV size of the take so far plus 1 GB.
- Hold a `kIOPMAssertPreventUserIdleSystemSleep` assertion while recording. It does not stop sleep on lid close, from the Apple menu, or on low battery (IOPMLib.h). A segment break catches the sample-time jump after a wake.

**Echo (R14).** Headphones are the only live measure. From Release 2, when a session has an app source (0006) and the output is the built-in speakers, show "Use headphones". Voice processing is not used: it needs AVAudioEngine, builds its own aggregate device, ducks the call, and changes the raw signal. Offline bleed removal is R14 work in Release 3.

## Consequences

- "No data loss" means: a process crash loses nothing that the writer wrote; a power loss or a kernel panic loses at most 5 s; an unplug loses the time until the device comes back.
- Release 1 uses double disk space for each take (CAF and WAV) until the drift spike passes.
- Hardware checks go in the run ledger as manual checks: two USB microphones for one hour (drift in ppm), a clap on two devices (alignment within 1 ms, latency sign), an unplug and replug, a rate change in Audio MIDI Setup during a take, `kill -9` during a four-track take, a forced power-off, 44.1 kHz and 48 kHz devices together, a full disk during a take and an open after space is freed, and `tccutil reset Microphone` before a take, and one hour on a Bluetooth headset that must stay one segment.

## Alternatives considered

- **AUHAL, one input unit per device.** Kept as the fallback. It adds a unit and a render call for the same timestamps.
- **`ExtAudioFileWriteAsync` from the IOProc.** Rejected: it lost 0.27 s on SIGKILL in a local test.
- **WAV with header updates during capture.** Rejected: a reader sees 0 frames after a crash until a repair step runs.
- **Drift correction during playback.** Rejected for Release 1. Every playback and export path would need a resampler. One correction at stop keeps one invariant: every pool file is at the session rate.
- **Recovery at launch, off main, for every listed session.** Rejected by the plan gate: it and `Studio.open` could both write `session.xml`.
