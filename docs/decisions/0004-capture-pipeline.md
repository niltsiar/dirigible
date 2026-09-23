# 0004. Capture pipeline: one IOProc per device, CAF segments, recovery on open

- Status: accepted
- Date: 2026-09-24

## Context

R3 and R4 ask for several sources at the same time, each on its own track, without an aggregate device. `AGENTS.md` asks for no data loss after a crash, an unplug, or a full disk, and for the timing data to align devices with different clocks. The evidence is in `docs/research/capture.md` and in local tests:

- A CAF writer killed with SIGKILL leaves every written second readable. A WAV writer leaves a header with 0 bytes (`.scratchpads/verify/caf-crash/`, 21.0 s of 21 s against 0 s).
- `ExtAudioFileWriteAsync` lost 0.27 s on SIGKILL. Synchronous writes lost nothing.
- `AudioDeviceCreateIOProcIDWithBlock` gives the device sample time and host time for each buffer. Process taps (0006) use the same path.

The plan gate (two rounds) added the rules for rate changes, reconnects, recovery ownership, and disk and power failures.

## Decision

**Capture.**

- One IOProc per input device, from `AudioDeviceCreateIOProcIDWithBlock` with a NULL queue. AUHAL is the fallback if the IOProc path fails on hardware. This replaces the "AUHAL, one input unit per device" text in 0001.
- The IOProc copies the whole input buffer list into one SPSC ring per device (0005) and does nothing else. Each ring record header holds the sample time, the host time, the frame count, `mNumberBuffers`, and each `mDataByteSize`. If the ring is full, the IOProc adds the lost frames to an atomic counter. The UI shows this counter during a take.
- Each ring holds 10 s of audio. It is allocated before the IOProc starts.
- Each device has one writer on its own serial `DispatchQueue`, never on the cooperative pool. The writer drains the ring every 50 ms and takes out the channels of each track (0002, `Track.route`). It writes one float32 CAF per track with synchronous writes.
- The writer checks each record's byte sizes against frames x channels x 4. On a mismatch, it closes the segment at that record.
- Every 5 s, the writer calls `fcntl(F_FULLFSYNC)` on each CAF and sidecar.

**Timing.**

- Each segment has a sidecar file next to it. The first record holds the capture header: device UID, device name, nominal rate, channel count, input latency, and the host time and sample time of the first frame. After that, the writer appends a checkpoint about once per second: the file frame index, the sample time, and the host time.
- The take anchor: timeline start = playhead at record start + (first-frame host time - take start host time) - latency. Host time never crosses a take, because host time is valid for one boot only.

**Segments.** A new segment file starts on any of these events:

- a nominal rate change, a stream format change, or IsAlive false (property listeners on each device);
- a byte size mismatch in a ring record;
- a backward jump of the sample time, or a forward jump of more than 2 s.

A forward jump of 2 s or less gets silence, and the writer logs the gap. The names are `<trackID>-<take>-<segment>.caf` and `.sidecar`.

**Device lost and back.** While a take runs, the recorder listens to `kAudioHardwarePropertyDevices`. When the UID of a lost device comes back, the recorder restarts its IOProc into a new segment. Until then, the track shows a persistent "device lost" state. The other tracks continue.

**Finalize at stop.**

- Fit a line through the checkpoints of each device segment. The slope is the real rate.
- Always write a 24-bit WAV at the session rate (0003) with `AudioConverter`. Resample from the fitted rate when the drift over the segment is more than 1 ms. Store `resampledFromRate` in the `<capture>` element.
- If the fitted rate is more than 1000 ppm from nominal, do not trust it. Convert from the nominal rate and set `driftCorrected="false"`. The clip gets a warning mark.
- Release 1 keeps every raw CAF until the hardware drift spike confirms the fit. A later run deletes a CAF only after its WAV passes the frame-count check.
- The player and the export never read a CAF.

**Recovery has one owner: `Studio.open`.**

- The `<recording>` element in `session.xml` (0003) is the single source of truth. An active-recordings list in Application Support is only a hint that tells the app which sessions to reopen at launch.
- Start order: (1) save `session.xml` atomically with the new tracks and the `<recording>` element; (2) add the session URL to the list; (3) start the IOProcs. A crash between (1) and (2): the app does not reopen the session at launch, but the next open recovers it.
- Stop order: (1) finalize; (2) save `session.xml` atomically with the clips and without `<recording>`; (3) remove the URL from the list. A crash between (2) and (3): open finds no `<recording>` and removes the stale entry.
- `Studio.open` is `async`. It reads `session.xml` off the main actor. If `<recording>` is present, it runs finalize on the segment files it finds, saves, and then returns the studio. It discards a torn last sidecar record. A segment with no usable checkpoint goes on the timeline from its first record at the nominal rate, with a warning mark. Recovery is idempotent. Nothing else writes `session.xml` during recovery.

**Studio state.** `Studio` has one state: `idle`, `playing`, or `recording(Take)`. In Release 1, an edit or an undo throws `.busy` while the state is `recording`. Stop records one History entry.

**Disk and sleep.**

- Before a take, check the free space against the armed tracks x rate x 4 bytes, plus the finalize headroom. Show the remaining record time. Below a threshold, stop the take cleanly and tell the user.
- Hold a `kIOPMAssertPreventUserIdleSystemSleep` assertion while recording. It does not stop sleep on lid close, from the Apple menu, or on low battery (IOPMLib.h). A segment break catches the sample-time jump after a wake.

**Echo (R14, Releases 1 and 2).** Headphones are the only live measure. When a session has an app source (0006) and the output is the built-in speakers, show "Use headphones". Voice processing is not used: it needs AVAudioEngine, builds its own aggregate device, ducks the call, and changes the raw signal. Offline bleed removal is R14 work in Release 3.

## Consequences

- "No data loss" means: a process crash loses nothing that the writer wrote; a power loss or a kernel panic loses at most 5 s; an unplug loses the time until the device comes back.
- Release 1 uses double disk space for each take (CAF and WAV) until the drift spike passes.
- Hardware checks go in the run ledger as manual checks: two USB microphones for one hour (drift in ppm), a clap on two devices (alignment within 1 ms, latency sign), an unplug and replug, a rate change in Audio MIDI Setup during a take, `kill -9` during a four-track take, a forced power-off, 44.1 kHz and 48 kHz devices together.

## Alternatives considered

- **AUHAL, one input unit per device.** Kept as the fallback. It adds a unit and a render call for the same timestamps.
- **`ExtAudioFileWriteAsync` from the IOProc.** Rejected: it lost 0.27 s on SIGKILL in a local test.
- **WAV with header updates during capture.** Rejected: a reader sees 0 frames after a crash until a repair step runs.
- **Drift correction during playback.** Rejected for Release 1. Every playback and export path would need a resampler. One correction at stop keeps one invariant: every pool file is at the session rate.
- **Recovery at launch, off main, for every listed session.** Rejected by the plan gate: it and `Studio.open` could both write `session.xml`.
