# 0044. Record monitor: a Listener per device with its own IOProc and a default output unit

- Status: accepted
- Date: 2026-10-10
- Accepted: 2026-10-10, after plan gates 1 and 2 of run `2026-10-10-record-monitor`.
- Amended: 2026-10-10. The speaker guard plays zeros when the output, or one of its active subdevices, is a loopback device of the listened input: the input when it is virtual, and each virtual device under an aggregate input. A failed transport or subdevice read, or an aggregate under itself, makes every output a loopback (fail closed), and the header shows the quiet text.
- Amended: 2026-10-10. Track > Monitor Track has the key Control-Command-M. A text field has no Control-Command-M, so the track name field keeps its keys. Each device track header has a Monitor button with the same state.
- Amended: 2026-10-11, run ui-polish-header. The full quiet sentence wrapped to 3 to 13 lines in a header row. The row shows "No monitor sound": on line 3 in a row of 80 pt or more, as a speaker symbol in a lower row. The full sentence is the help tag and the VoiceOver label.
- Amends: 0013 (a second owner of an input IOProc), 0015 (the meter request includes the listened tracks), 0039 (playback during a take goes to Release 3 run 9).

## Context

F02 asks for a monitor per track: the input of a track plays in the output, before and during a take (tester items B1.5 and B2.10). Hindenburg PRO, Logic Pro, and GarageBand have a manual monitor per track; Logic and GarageBand monitor during a take and with no arm ([research](../research/record-monitor.md)). In code, "listen" is this sound path. "Monitor" keeps its 0015 meaning, the meter of Monitor Inputs.

Constraints: the take writer IOProc is the no-data-loss path (0013); `CaptureRing` has one consumer, the drain, which allocates; 0015 finishes every monitor writer at the hand-over; input and output are two devices with two clocks and no aggregate device (0004); the Player starts and stops its engine at each play (0016).

Probes P1 to P9 (2026-10-10, macOS 15.7.9, x86_64, Swift 6.2.4; run `2026-10-10-record-monitor`, `probe/output.txt`):

- P1. The built-in microphone has a 1919-frame stream latency (40 ms) and the speakers 284 frames (5.9 ms). Both have one clock domain. The data source of the speakers cannot be set from code.
- P2. Microphone IOProc, an SPSC ring, and an AUHAL DefaultOutput render at 512-frame buffers: the time-stamp delta of a frame is 42.5 ms; the HAL part is 25.3 ms, so the ring and the IO phase add 17.2 ms. The fill after a pop is 0 or 512, because the order of the two IO threads changes per cycle.
- P3. Loopback Audio (virtual) against the speakers: -13.2 and -13.8 ppm. A default output change stops the render about 0.5 s, and the ring keeps that delay.
- P4. An `AVAudioSourceNode` renders across player node stop and play with 0 gaps, but `engine.stop()` stops it.
- P5. An AUHAL DefaultOutput unit follows a change of the default output by itself (longest render interval 467 ms). A raw output IOProc stays on its device. A C listener on the default output gets its call 17 to 78 ms after the change.
- P6. The AUHAL converts a 44.1 kHz client to a 48 kHz device with no pitch or level change.
- P7. The first AUHAL in a process takes 1673 ms to its first render (1401 ms component load, at load 15); later ones 62 to 103 ms.
- P8. Two IOProcs on the built-in microphone run back to back on one IO thread. The second has 0 sample-time gaps across the stop of the first, and the first gets 0 calls after its destroy returns. This confirms the 0015 Q1 inference on an input device.
- P9. After `AudioOutputUnitStop` returns, the render gets 0 calls (20 rounds).

## Decision

**Output.** Each listened device has one `Listener`. It owns one AUHAL `kAudioUnitSubType_DefaultOutput` unit. The render is a static C `AURenderCallback` of a nonisolated type (0013) on the IO thread of the unit. The client format is two channels of Float32 at the input rate: the unit converts the rate (P6) and follows the default output (P5). The monitor does not change the IO buffer size of a device. It does not use the Player engine: 0016 stops that engine at each stop (P4).

**Feed.** The `Listener` owns its own input IOProc on the device. Its context is a `ListenRing`: a stereo SPSC frame ring with a channel map, the drift state, the speaker flag, and counters. The IO side is pointers and atomics only. One lock in the context guards control state that no IO callback reads (Speaker guard). No take step touches it, so the sound has no gap at the take start, the hand-over, or the come back (P8). The take writer, `CaptureRing`, `DeviceWriter`, and the 0015 hand-over do not change. A mono track plays in both channels and a stereo track left and right, at unity gain. Mute, solo, and the track gain do not apply. An app track has no monitor: the tap is unmuted, so the user hears the app already.

**Bound of the push.** The push reads no channel by a map index. It walks the buffer list of each call, buffer by buffer and channel by channel, and adds a channel when the map has its device channel number. It ignores a device channel above 64. So a map channel that the list does not have plays silence, and a layout change (for example a Bluetooth profile switch) needs no step. Interleaved buffers and several streams use the same walk.

**Drift.** The render reads the minimum fill after a pop, plus the corrections so far, over a tumbling window of 1 s. A 100 ms window is shorter than the beat of the push and pull periods at 48 kHz in and 44.1 kHz out (131 ms), so the phase alone moves the minimum and the rule corrects all the time. The target is the larger of the input block and the pull at the input rate, plus 2 ms, set at each start and restart: one pull interval with no push (a phase crossing of the two clocks) then leaves 2 ms, not an underrun. The band is 1 ms. At the window end, an error outside the band sets the correction, and the render drops or repeats one frame of it per call. An error more than one block plus 8 ms over the target skips to the target at once (P3). A larger push or pull makes a new rule. A prime waits for the target plus one input block. An underrun gives zeros and primes again. In a simulation of 2 h over eight pairs of IO sizes, the corrections stayed within the drift plus two blocks, and at 0 ppm they stopped in the first minute. A full ring drops the push and counts it.

**Speaker guard.** The speaker flag is an atomic in the context of each `Listener`, true at a new ring. Each `Listener` has its own C listener on the default output of the system object, and a data source listener on each default output that it reads, with its context as client data. It removes them at off. One function writes the flag: it takes a ticket from a counter, reads the default output, adds the data source listener, reads the flag, and stores it only when no newer ticket stored first. The context keeps the set of watched devices and a closed flag under one lock. Off sets the closed flag before it removes a listener, and a refresh adds no listener after it: a refresh that added one during an off removes it. The flag uses the rule of the 0015 banner (`isBuiltInSpeakers` through the same read). A failed read of the transport or the data source gives false. A failed read of the default output device gives true: the safe side. While the flag is true, the render pulls and writes zeros. The banner follows the 0015 speaker read, so it shows when the default output is the built-in speakers. The menu item keeps its state. External speakers are not detected. The 0015 device-list listener does not change.

**Owner and order.** `Studio.listen(to:)` sets the request. Each change runs in its own order, not in the monitor turns of 0015: the hand-over holds a monitor turn while an app attach waits for a prompt. A device that leaves the request plays zeros before the first await and is released before the return. The monitor needs no arm and works during a take and a finalize. `settle()` empties the listen request first. The `Listener` keeps the attach, retry, and keep rules of 0013 and 0015 for its own IOProc. An output unit that fails to start sends the `Listener` to its retry. A failed stop keeps the ring and does not flush it. A retry after a failed stop or detach makes a new ring and context, and counts against the keep limit, so no ring gets two producers or two consumers. A clean IOProc destroy (P8) and a clean unit stop (P9) free the ring bytes; after a failed one, the ring stays for the process life. The context (its atomics and its lock) stays for the process life in each case, because a listener call can be in progress after its removal (0013).

**State in the window.** A `Listener` that waits or stops retrying reports it. `Studio` keeps the quiet state per device and takes a report only from the current `Listener` of that device. The quiet tracks are the listened tracks of a quiet device, so off leaves no text. The tracks of a quiet device show "No monitor sound" in the track header, with the full sentence "No monitor sound. Turn Monitor Track off and on." as the help tag and the VoiceOver label.

**Playback during a take.** No playback runs during a take, and mute and solo stay off during a take. Pre-roll (Release 3 run 9) needs playback during a take with a take anchor that includes the output latency, so that run decides both.

**CLI (0011).** No `dirigible` command and no MCP tool: the monitor writes nothing to a package, and its output is sound for a person (the 0015 reason).

## Consequences

- 0013 gets an amended line: a `Listener` also owns an input IOProc on a device (0044); its ring has the same callback and keep rules.
- 0015 gets an amended line: the window meters the listened tracks with the armed tracks (0044).
- 0039 gets an amended line: playback, mute, and solo during a take are decided in Release 3 run 9 (0044).
- During a take, a listened device runs two IOProcs (the take writer and the `Listener`), and three during the hand-over.
- The ring target costs one input block of delay (10.7 ms at 512 frames) over a 2 ms target.
- The heard latency from the built-in microphone is about 102 ms, because 40.8 ms is the microphone device and stream latency. The guide says so.
- The first monitor start in a process can take up to 2 s (P7). A warm-up of the component is a Later item.
- A default output change silences the monitor for up to about 0.5 s (P5).
- One dropped or repeated frame is the drift correction. On one clock domain, it runs only in the first minute after a start, to correct the prime (at most one input block).
- After a render gap, the delay comes back to the target within 2 s (the end of the first full 1 s window).
- Each `Listener` adds a default-output listener and data source listeners for its life.

## Alternatives considered

- **A source node in the Player engine.** Rejected: 0016 stops the engine at each stop (P4), and the monitor needs the output while stopped.
- **A second `AVAudioEngine`.** Rejected: a block render against 0013, and no gain over the AUHAL (P5, P6).
- **A raw output IOProc on the default output device.** Rejected: it does not follow the default output (P5) and needs its own rate converter.
- **A feed that the running writer IOProc fills.** Rejected: it changes the take writer IOProc, and at the hand-over two producers push the same frames.
- **A monitor writer that the hand-over keeps, with a feed per appearance.** Rejected: a feed swap with a render barrier, a `DeviceWriter` split, and three changed 0015 rules, to save about 120 lines of retry code.
- **A varying-rate resampler for the drift.** Rejected: a filter state on the IO thread for a drift of 14 ppm (P3).
- **A ring target of 2 ms.** Rejected: the fill moves by whole input blocks, so a phase crossing of two clocks underruns or skips.
- **One process-life speaker flag that the 0015 device-list listener sets.** Rejected: a new rule in that listener, a flag that parallel tests share, and a second read that skips the data source listener.
- **A 128-frame IO buffer while the monitor runs.** Rejected for now: it changes the IO of every client of the device. Manual check M1 decides if the latency needs it.
