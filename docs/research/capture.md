# Audio capture

Date: 2026-09-23

## Scope

This document answers the capture questions in `docs/requirements/brief.md`: device capture without an aggregate device (R3, R4), clock alignment, the real-time handoff to the file writer, crash-safe capture files, app audio capture (R12), and the remote guest in the local microphone. The limits come from `CODING_STANDARDS.md` (Safety, Concurrency: no data loss, no real-time lock, one clock per device) and `docs/decisions/0001-native-swift-stack.md`.

Sources are the macOS 26 SDK headers on the development Mac (`xcrun --show-sdk-path`), Apple documentation, and open source. Claims that this research did not confirm in a primary source have the mark "(unconfirmed)". The mark "(tested)" means a local test on macOS 15.7 on 2026-09-23. The scripts are in the session scratchpad and are not in git.

## 1. Multi-device capture without an aggregate device

### Facts

- **HAL IOProc.** `AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, queue, block)` registers a block on one device (AudioHardware.h, macOS 10.7). The block gets `inInputTime`: "the time at which the first frame in the data was acquired from the hardware". `AudioTimeStamp` has `mSampleTime` (the device sample clock) and `mHostTime` (`mach_absolute_time`). With a `NULL` queue, the HAL calls the block directly on its real-time IO thread. The block type has the `CA_REALTIME_API` mark.
- **IOProc data format.** The block gets the device stream format with no conversion. For PCM devices on macOS this is 32-bit float (unconfirmed for all drivers). `kAudioDevicePropertyIOProcStreamUsage` turns off streams that the IOProc does not use, for example the output streams.
- **AUHAL.** `kAudioUnitSubType_HALOutput`, input on element 1 with `kAudioOutputUnitProperty_EnableIO`, device set with `kAudioOutputUnitProperty_CurrentDevice` after IO is enabled (TN2091). The input callback gets an `AudioTimeStamp` and must call `AudioUnitRender` into a buffer list that the app allocates before start. The AUHAL converts format and maps channels, but it does not convert sample rate on the input side (TN2091).
- **AVAudioEngine.** On macOS the input node uses the default input device (AVAudioIONode.h). To use another device, set `kAudioOutputUnitProperty_CurrentDevice` on the input node's audio unit (unconfirmed for more than one engine at a time). `installTap` gives `AVAudioTime` with sample time and host time, but the tap block does not run on the IO thread, and the engine can ignore the requested buffer size (unconfirmed).
- **Process taps use the same path.** A process tap is read through an IOProc on a private aggregate device (Apple sample "Capturing system audio with Core Audio taps", AudioCap). An IOProc capture path serves devices and taps.

### Options

| Option | Own sample and host time per buffer | Real-time thread | Code size |
|---|---|---|---|
| IOProc block per device | Yes, `inInputTime` | Yes, with a `NULL` queue | Smallest. No render call, no unit setup. |
| AUHAL per device | Yes, in the input callback | Yes | Medium. Unit setup, `AudioUnitRender`, preallocated buffer list. |
| AVAudioEngine per device | Yes, `AVAudioTime` in the tap | No, the tap is late and not real-time | Large graph per device. Device selection is not direct. |

### Recommendation

Use one IOProc block per device (`AudioDeviceCreateIOProcIDWithBlock`, `NULL` queue). It gives the device sample time and host time for each buffer. It is the same code path as the process tap (question 5). It needs no audio unit. Turn off the output streams with `kAudioDevicePropertyIOProcStreamUsage`. Create the block in a `nonisolated` function and mark it `@Sendable` (`CODING_STANDARDS.md` Concurrency; decision 0013 Callbacks). Do not capture a Swift class in the block. Capture an unsafe pointer to preallocated state.

This changes the text "AUHAL, one input unit per device" in decision 0001. Record the change in the first capture decision. Keep the AUHAL as the fallback if a device needs format conversion or a channel map.

## 2. Clock alignment across devices

### Facts

- Each device has its own sample clock. Two devices at "48 kHz" run at slightly different real rates. Crystal tolerance of ±20 to ±100 ppm is common (unconfirmed). 50 ppm is 180 ms of drift per hour.
- The host clock (`mach_absolute_time`) is common to all devices and taps in one process. `AudioTimeStamp.mHostTime` maps each device sample time to the host clock.
- `kAudioDevicePropertyActualSampleRate` gives the HAL estimate of the real rate. `kAudioDevicePropertyLatency`, `kAudioStreamPropertyLatency`, and `kAudioDevicePropertySafetyOffset` give the input latency in frames (AudioHardware.h). Whether `inInputTime` already includes these latencies is unconfirmed.
- A dropout (overload, device glitch) shows as a jump in `mSampleTime` between two callbacks.
- **Hindenburg.** No public document says how Hindenburg aligns devices (searched 2026-09-23).
- **Audio Hijack.** Release notes 4.0.4 say "Clock synchronization across devices has been improved" and "Tracking of audio device sample clocks also now works better when the device is providing erroneous information". Release 4.0.5 says "Clock synchronization and drift correction have been improved when device clocks experience discontinuities". The method is not documented.
- **Core Audio aggregate devices** correct drift by resampling sub-devices to the clock device (`kAudioSubTapDriftCompensationKey`, `kAudioSubDevicePropertyDriftCompensation`). This is the job that R4 moves into the app.

### Options

1. Resample in real time during capture. Risky on the IO thread and it changes the raw audio.
2. Store raw audio and timing data. Resample once at stop, in the step that converts the capture file to WAV or FLAC (question 4).
3. Store raw audio and timing data. Correct at playback and at export only (the edit uses a rate per clip).

### Recommendation

Store raw audio and a timing log. Correct drift at stop (option 2).

Store per capture file:

- Device UID, device name, nominal sample rate, channel count, input latency in frames (device + stream + safety offset).
- The first frame: `mHostTime` and `mSampleTime`.
- A checkpoint about once per second: file frame index, `mSampleTime`, `mHostTime`. Append it to a sidecar file during capture, so a crash keeps it.
- Gaps: when `mSampleTime` jumps, the writer writes silence for the missing frames and logs the gap. Then file frame index equals device sample time minus the first sample time.

At stop:

- Fit a line through the checkpoints (sample time against host seconds). The slope is the real rate.
- In the conversion from CAF to WAV or FLAC, resample from the real rate to the nominal rate with `AudioConverter` (high quality complexity). Do this only when the drift over the file is more than a threshold. Start with 1 ms and tune it on hardware.
- Put the clip on the timeline at host time of the first frame minus the session start host time, minus the input latency.
- Save the real rate, the drift in ppm, and the offset in the session XML, so a later tool can check or redo the correction.

Update 2026-09-23: decision 0004 anchors each take to the playhead at record start plus host-time offsets inside the take. It does not use a session start host time, because host time is valid for one boot only.

## 3. Real-time handoff from the IO callback to the file writer

### Facts

- The Swift `Synchronization` module (`Atomic`) needs macOS 15. `swiftc -target x86_64-apple-macos14` fails with "'Atomic' is only available in macOS 15.0 or newer" (tested).
- **swift-atomics** (apple/swift-atomics) supports macOS 14. It is a third-party package under the repo rules, so it needs a decision record.
- **C target.** A SwiftPM C target with C11 `<stdatomic.h>` gives acquire and release loads and stores with no third-party code. Swift calls the C functions directly, with no allocation.
- **TPCircularBuffer** is a C ring buffer with a mirrored virtual memory map. It is third-party.
- **ExtAudioFileWriteAsync.** The header (ExtendedAudioFile.h) says: "Writes the provided buffer list to an internal ring buffer and notifies an internal thread to perform the write at a later time. The first time this is called, allocations may be performed. You can call this with 0 frames and null buffer in a non-time-critical context to initialize the asynchronous mechanism. Once initialized, subsequent calls are very efficient and do not take locks; thus this may be used to write to a file from a realtime thread." It also says: "Pending writes are not guaranteed to be flushed to disk until ExtAudioFileDispose is called." A slow disk gives `kExtAudioFileError_AsyncWriteBufferOverflow` (-66570).
- **ExtAudioFileWriteAsync loses the tail on a crash (tested).** A mono 48 kHz float CAF, written in 512-frame calls for 3.0 s, then `SIGKILL`: 131,072 frames on disk (exactly 512 KiB), 12,800 frames lost (0.27 s). The same test with synchronous `ExtAudioFileWrite` or `AudioFileWriteBytes` kept all 143,872 frames. The async writer seems to flush in blocks of about 512 KiB, which is 1.4 s of stereo float at 48 kHz (unconfirmed beyond this one test).

### Options

| Option | Real-time safe | New dependency | Crash loss |
|---|---|---|---|
| `ExtAudioFileWriteAsync` from the IO block | Yes (Apple header) | None | Up to one internal block (0.27 s seen, more for stereo). No control. |
| SPSC ring in a C target + writer thread with sync writes | Yes, if the ring is preallocated | None | Up to one drain period (for example 100 ms). |
| SPSC ring with swift-atomics | Yes | swift-atomics, needs a decision record | Same as the C target. |

### Recommendation

Update 2026-09-23: the team chose apple/swift-atomics over the C target (decision 0005). The ring design, the record header, and the dropped-frame counter below stay.

Use a small C target with a single-producer, single-consumer byte ring buffer (C11 atomics, storage allocated before start, about 60 lines). The IO block copies the input frames and a small header (`mSampleTime`, `mHostTime`, frame count) into the ring. It never blocks. If the ring is full, it counts the dropped frames in an atomic counter. A writer task per device drains the ring every 50 to 100 ms off the main actor and writes with synchronous `AudioFileWriteBytes` or `ExtAudioFileWrite`. The writer also appends the timing checkpoints (question 2). Size the ring for 2 s or more of audio.

`ExtAudioFileWriteAsync` is less code, but it hides the flush period and loses more audio in a crash. It does not meet "No data loss" as well as the ring.

Update 2026-09-23: decision 0004 gives each device writer its own serial dispatch queue, not a task, and sizes each ring for 10 s. Each ring record header carries the buffer sizes, so the writer finds a format change at the exact record.

## 4. Crash-safe capture file

### Facts

- **CAF spec.** "An `mChunkSize` value of `-1` indicates that the size of the data section for this chunk is unknown. In this case, the Audio Data chunk must appear last in the file so that the end of the Audio Data chunk is the same as the end of the file. This placement allows you to determine the data section size." Also: "When you read a CAF file whose audio data section size is not specified, you should determine the size and update the `mChunkSize` value for the Audio Data chunk."
- **AudioToolbox writes `-1` while it records (tested).** After `SIGKILL`, the CAF chunks were `desc` 32, `free` 4016, `data -1`. `afinfo` read the file and all the audio on disk.
- **WAV after a crash (tested).** The same test with `kAudioFileWAVEType`: the file had 512 KiB of samples on disk, but `afinfo` reported "audio bytes: 0" and a duration of 0. The header has the data size only after close.
- CAF sizes are 64-bit. A WAV file stops at 4 GiB (RF64 is the extension). Stereo float at 48 kHz fills 4 GiB in about 3.1 hours.

### Options

1. Capture to CAF (`kAudioFileCAFType`, the device format). At stop, convert to WAV or FLAC (with the drift correction of question 2).
2. Capture to WAV. Rewrite the header sizes every few seconds. At launch, repair the header from the file size. This needs our own RIFF code, and it has the 4 GiB limit during capture.

### Recommendation

Capture to CAF (option 1). AudioToolbox already writes a data chunk of size `-1`, and it reads such a file back after a crash.

Launch recovery:

1. At record start, write a marker in the session folder (for example the session XML with the state `recording`, saved atomically).
2. At launch, find the sessions that still have the marker.
3. For each capture CAF, open it with `AudioFile` and read the frame count. The reader uses the file size when the chunk size is `-1`. Cut a partial last frame.
4. Read the timing sidecar. Run the normal stop step: drift correction, conversion to WAV or FLAC, a check that the frame counts match.
5. Save the session XML atomically with the recovered clips. Remove the marker.
6. Delete a CAF only after its converted clip passes the frame count check.

Update 2026-09-23: decision 0004 keeps the `recording` marker in `session.xml` as the single source of truth and adds an active-recordings list as a reopen hint. Only `Studio.open` runs recovery. Finalize always writes WAV at the session rate. Release 1 keeps the raw CAF until the hardware drift spike passes, so step 6 does not delete it yet.

Update 2026-11-04: decision 0071 runs step 6. The sweep deletes the CAF of a placed segment after its WAV passes the gate of frames, rate choice, and alignment to the host clock.

## 5. App audio capture (R12)

### Facts: Core Audio process taps

- `AudioHardwareCreateProcessTap(CATapDescription*, AudioObjectID*)` and `AudioHardwareDestroyProcessTap` are `API_AVAILABLE(macos(14.2))` (AudioHardwareTapping.h). AudioCap says the API arrived in macOS 14.4. The header is the primary source. The gap between 14.2 and 14.4 is unconfirmed.
- To read a tap, add it to an aggregate device (`kAudioAggregateDeviceTapListKey`, `kAudioSubTapUIDKey`) and run an IOProc on that device (Apple sample, AudioCap). `kAudioAggregateDeviceIsPrivateKey` = 1 makes the aggregate "private to the process that created it" and not persistent. AudioCap also sets the default output device as the main sub-device and `kAudioSubTapDriftCompensationKey` = true.
- **R4 conflict.** A tap needs a private aggregate device. This aggregate holds one tap, the user does not see it, and it does not combine microphones. The team must confirm that R4 permits this and record it in a decision.
- `CATapDescription(stereoMixdownOfProcesses:)` takes process `AudioObjectID`s. `privateTap` hides the tap from other processes. `muteBehavior = .unmuted` lets the user still hear the call. `kAudioTapPropertyDescription` is settable, so the app can change the process list of a live tap (header).
- Process discovery: `kAudioHardwarePropertyProcessObjectList`, `kAudioHardwarePropertyTranslatePIDToProcessObject`, `kAudioProcessPropertyPID`, `kAudioProcessPropertyBundleID`, `kAudioProcessPropertyIsRunningOutput` (AudioHardware.h).
- `CATapDescription.bundleIDs` and `processRestoreEnabled` are `macos(26.0)`. They are not on macOS 14.
- **Permission.** Add `NSAudioCaptureUsageDescription` to Info.plist (Apple sample: "you need to include the `NSAudioCaptureUsageDescription` key in your Info.plist file"). The system asks "the first time you start recording from an aggregate device that contains a tap". The TCC service is `kTCCServiceAudioCapture` (AudioCap). No public API checks or requests this permission. AudioCap uses private TCC functions. A denied tap gives silence and no error (parley issue 221; unconfirmed in Apple docs).
- **Timestamps.** The tap IOProc gets the same `AudioTimeStamp` as a device. The clock is the aggregate clock, which is the main sub-device (the output device).
- **Helper processes.** Corrected by `docs/research/process-taps.md` section 1: the Teams silence is solved, the Teams helper is `ModuleHost`, and AudioCap does not group a helper with its app. The sentences below are the claims of 2026-09-26 before that correction. The process that plays the audio is often not the main app. Chrome plays audio from a separate audio service process "since v76" (issue in SamWongML/macos-audio-recording). Browser meetings use renderer and helper processes (Recall.ai). One report says a tap on Microsoft Teams gave only zero buffers, while ScreenCaptureKit captured Teams (pasrom/meeting-transcriber issue 79, not solved). For Teams the audio process is probably "Microsoft Teams WebView Helper" or a similar helper, and for Zoom it is probably `zoom.us` itself (both unconfirmed). Safari plays through `com.apple.WebKit.GPU`, which is outside `Safari.app` (unconfirmed).
- AudioCap finds the app of a helper from its executable path (`proc_pidpath`, then the parent `.app` bundle).

### Facts: ScreenCaptureKit audio

- `SCStreamConfiguration.capturesAudio`, `sampleRate` (default 48000), `channelCount` (default 2), and `excludesCurrentProcessAudio` are macOS 13.0 (SCStream.h). `captureMicrophone` is macOS 15.
- `SCContentFilter(display:including:exceptingWindows:)` filters by `SCRunningApplication`. The stream needs a display, even for audio only.
- Audio comes as `CMSampleBuffer` (`SCStreamOutputType.audio`). Its presentation time uses `SCStream.synchronizationClock` (macOS 13). `CMSyncConvertTime` maps it to the host clock.
- It needs the Screen Recording permission. macOS 15 asks again every month for apps that do not use the system picker (Michael Tsai, TechRadar).

### Facts: macOS 14.0 and 14.1

- No process taps. ScreenCaptureKit audio is the only Apple API for app audio. macOS 14.2 and later is a free update on the same hardware.

### Options

1. Process taps only. App capture needs macOS 14.2 or later. On 14.0 and 14.1 the UI tells the user to update macOS.
2. Process taps, with ScreenCaptureKit on 14.0 and 14.1 or when a tap stays silent.
3. ScreenCaptureKit only.

### Recommendation

Use process taps (option 1). Taps use the same IOProc path and the same timestamps as devices, and they need only the "System Audio Recording" permission, not Screen Recording.

- Pick an app, not a process. Tap every process object whose executable is inside the app bundle, plus known helpers. Watch `kAudioHardwarePropertyProcessObjectList` and update the tap description when helpers start or stop. Corrected by `docs/research/process-taps.md` section 1 and probe P10: a live update of the tap gives `!hog`, so decision 0030 rebuilds the tap.
- One tap and one private aggregate device per app source, so each source has its own track (R12). Set `privateTap` and `.unmuted`.
- Add `NSAudioCaptureUsageDescription` in English and Spanish (`Support/Info.plist`, `es.lproj/InfoPlist.strings`), checked by `AppBundleTests`.
- Show a warning when the tap gives only zero samples for some seconds while the app has `IsRunningOutput` = 1. Link to the privacy settings.
- Keep ScreenCaptureKit in the backlog. Add it only if the spike shows that taps cannot capture Teams or Zoom.

## 6. Remote guest in the local microphone

### Facts

- Rogue Amoeba: "To prevent echo and feedback loops, it's best for all parties to wear headphones when speaking over voice chat."
- `setVoiceProcessingEnabled` needs "both input and output nodes to be in the voice processing mode" and a stopped engine. "The output format of the input node and the input format of the output node have to be the same" (AVAudioIONode.h). It works through AVAudioEngine or AUVoiceProcessingIO, not through an IOProc.
- Voice processing builds its own internal aggregate device. It fails when the input and the output are different devices ("client-side input and output formats do not match", Apple forums thread 810129, no answer). It can change the input channel count (forums thread 710151).
- It ducks "other audio". WWDC23 session 10235: "All the audio streams other than the voice audio stream from your app are considered as 'other audio'". The call app output is "other audio" for us, so the user would hear the guest quieter.
- It also applies noise suppression and gain control (WWDC23). A podcast recorder wants the raw signal.
- The call app (Teams, Zoom) runs its own echo cancellation on what it sends. Our raw microphone capture does not get that processing.

### Recommendation

Headphones are the default and the only live measure. Do not use voice processing in the capture path. It needs AVAudioEngine, it builds an aggregate device (R4), it ducks the call, and it changes the raw audio.

- When a session has an app source and the output device is the built-in speakers, show a warning: "Use headphones".
- Put an offline bleed remover in the backlog. It uses the app track as the reference signal for an adaptive filter at edit time (R8 work).

## Microphone permission (ad-hoc signed, not sandboxed)

- The app needs `NSMicrophoneUsageDescription` in Info.plist (already in `Support/Info.plist`). Without it, TCC stops the app when it opens the microphone (unconfirmed for Core Audio IOProc access).
- `com.apple.security.device.audio-input` is needed only with the hardened runtime or the sandbox. Without it under hardened runtime, TCC denies and shows no prompt (orbstack issue 2546). Dirigible has neither (decision 0001), so it needs no entitlement.
- `AVCaptureDevice.requestAccess(for: .audio)` shows the prompt. `authorizationStatus(for: .audio)` reads the state. Call it before the first IOProc start. Core Audio input without the grant gives silence (unconfirmed).
- TCC ties the grant to the code signature. An ad-hoc signature changes on each build, so macOS asks again (decision 0001). A local self-signed identity keeps the grant.
- TCC gives the grant to the "responsible" process. A binary started from Terminal asks for Terminal's permission (unconfirmed). Start the app with `open build/Dirigible.app` (`make run`).
- `tccutil reset Microphone <bundle id>` and `tccutil reset AudioCapture <bundle id>` reset the state for manual checks (unconfirmed for `AudioCapture`).

## Risks to prove with a spike

1. Two USB microphones and the built-in microphone record at the same time with one IOProc each, for one hour, with no dropouts. Measure the drift in ppm from the checkpoints.
2. A clap recorded on two devices lines up within 1 ms after the drift correction and the latency offset. This proves the latency sign and whether `inInputTime` includes the latency.
3. A device unplug during capture: the other tracks continue, the CAF of the lost device stays readable, and the gap is logged.
4. `kill -9` during a four-track capture: launch recovery restores all tracks. Loss is less than one drain period.
5. A process tap captures a real Teams call, a Zoom call, a Slack huddle, and a meeting in Chrome and Safari. Find which processes play the audio.
6. The tap works on macOS 14.2 and 14.3, not only on 14.4 and later.
7. The System Audio Recording prompt appears for the ad-hoc signed app. A denial is detectable.
8. The IOProc on the tap aggregate does not change the output device, its sample rate, or the latency that the user hears.
9. A device that runs at 44.1 kHz and one at 48 kHz record together, and the conversion at stop gives the session rate.

## Sources

- macOS 26 SDK headers: `CoreAudio/AudioHardware.h`, `CoreAudio/AudioHardwareTapping.h`, `CoreAudio/CATapDescription.h`, `AudioToolbox/ExtendedAudioFile.h`, `AVFAudio/AVAudioIONode.h`, `ScreenCaptureKit/SCStream.h`.
- Apple, "Capturing system audio with Core Audio taps": https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps
- Apple, TN2091 "Device input using the HAL Output Audio Unit": https://developer.apple.com/library/archive/technotes/tn2091/_index.html
- Apple, Core Audio Format Specification: https://developer.apple.com/library/archive/documentation/MusicAudio/Reference/CAFSpec/CAF_spec/CAF_spec.html
- Apple, WWDC23 "What's new in voice processing": https://developer.apple.com/videos/play/wwdc2023/10235
- Apple Developer Forums, voice processing with different devices: https://developer.apple.com/forums/thread/810129
- Apple Developer Forums, voice processing changes the channel count: https://developer.apple.com/forums/thread/710151
- Apple, Audio Input Entitlement: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.audio-input
- insidegui/AudioCap: https://github.com/insidegui/AudioCap
- Recall.ai, "Core Audio Taps: A deep-dive": https://www.recall.ai/blog/core-audio-taps
- pasrom/meeting-transcriber issue 79 (silent Teams tap): https://github.com/pasrom/meeting-transcriber/issues/79
- fmasi/parley issue 221 (tap against ScreenCaptureKit): https://github.com/fmasi/parley/issues/221
- SamWongML/macos-audio-recording issue 12 (browser helper processes): https://github.com/SamWongML/macos-audio-recording/issues/12
- orbstack issue 2546 (missing audio-input entitlement): https://github.com/orbstack/orbstack/issues/2546
- Rogue Amoeba, VoIP recording tips: https://rogueamoeba.com/support/knowledgebase/?showArticle=AudioHijack-VoiceChatRecording
- Rogue Amoeba, Audio Hijack release notes: https://rogueamoeba.com/support/releasenotes/?product=Audio+Hijack
- Michael Tsai, Sequoia screen recording prompts: https://mjtsai.com/blog/2024/08/08/sequoia-screen-recording-prompts-and-the-persistent-content-capture-entitlement/
- TechRadar, monthly screen recording prompts: https://www.techradar.com/computing/mac-os/on-macos-sequoia-youll-only-have-to-deal-with-screen-recording-permission-pop-ups-once-a-month-rather-than-once-a-week
- apple/swift-atomics: https://github.com/apple/swift-atomics
- michaeltyson/TPCircularBuffer: https://github.com/michaeltyson/TPCircularBuffer
