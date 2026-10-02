# Core Audio process taps: setup, permission, helper processes, and Hindenburg

Date: 2026-10-02

## Scope

This document answers the research questions of the run `2026-10-02-app-sources`. It adds to `docs/research/capture.md` section 5 and to decision 0006. It does not repeat them. Section 1 lists the facts that change those two documents.

Sources are source code at a named commit, the macOS SDK 26.2 headers on the development Mac (`xcrun --show-sdk-path`), Apple documentation, issue threads with measured logs, and Hindenburg pages. Each claim has a bracket tag. The Sources section defines each tag. The mark "(unconfirmed)" means that no primary source confirms the claim. A sentence that starts with "Inference:" is our reading of the sources. A claim from an issue thread is "measured" only when the thread shows the measurement. Nothing in this document was tested on our Mac. Section 7 lists the probe questions.

## 1. Corrections to capture.md section 5 and decision 0006

1. **The Teams tap silence is solved.** capture.md says that pasrom/meeting-transcriber issue 79 is "not solved". The reporter closed it: the app was missing from the System Audio Recording list, and a reset of the permissions gave Teams audio [MT79]. A second problem was the PID set. A tap on the `MSTeams` main process alone gave only zeros. A tap on every process inside `Microsoft Teams.app` captured the call at -21 to -23 dB mean level [MT84].
2. **The Teams process that plays the call** was `Microsoft Teams ModuleHost` in a log of 2026-09-09: `isRunningOutput=true outputDevices=[102]`. The four other Teams processes in the tap had `isRunningOutput=false` [MT699]. capture.md guessed "Microsoft Teams WebView Helper". The guess is wrong for that log.
3. **AudioCap does not find the parent app.** capture.md says that AudioCap finds "the parent `.app` bundle" of a helper. `parentBundleURL` walks up from the executable path and stops at the first bundle [AC-PC]. For a helper app inside an app (for example `Google Chrome Helper.app` inside `Google Chrome.app`), the first bundle is the helper app itself. Inference: AudioCap shows a helper as its own app and never groups it with the main app.
4. **"Every process inside the app bundle" is not enough.** Safari plays call audio from `com.apple.WebKit.GPU`. Its executable is under `/System/Library/Frameworks/WebKit.framework`, outside `Safari.app`. A tap on Safari alone recorded an hour of silence [MT-PR] [MT524]. FaceTime audio comes from the daemon `com.apple.avconferenced` (measured on macOS 26.5.2) [MT-MID]. meeting-transcriber adds every Core Audio process whose "responsible" PID is the app. It uses the private function `responsibility_get_pid_responsible_for_pid` through `dlsym` [MT-PR]. The filter to Core Audio process objects is necessary: without it, the Safari set had about 28 PIDs and the tap gave zero bytes (reported, not shown) [MT524].
5. **The main sub-device rule of 0006 has conflicting measurements.** 0006 sets the main sub-device to the output device of the tapped process. The meeting-transcriber maintainer measured a tap anchored on the default output device. It captured a process that played to another device at full level (real device, virtual device, 44.1 kHz device, mono device, and voice processing). He also states that a tap anchored on a device that the process does not use "delivers no buffers at all" [MT699]. A user then measured the opposite with Teams on a USB speakerphone (input and output on one device): default output on another device gave a floor near -98.5 dBFS, and the Teams speakerphone as default output gave -20 to -26 dBFS [MT699]. The issue is open. This document does not choose. See probe P2.
6. **A denied tap gives zeros and no error.** Two measured reports confirm it. The tap returns `noErr`, the IOProc runs, and every sample is zero. Nothing is logged [MT524] [MT79]. New fact: either grant unlocks the tap, System Audio Recording or Screen Recording. With neither grant, the tap is silent (measured on macOS 26) [MT-CL] [MT524]. A tap that dies later has the same signature (section 6).
7. **The permission is in its own list.** On macOS 15 the path is System Settings > Privacy & Security > Screen & System Audio Recording, section "System Audio Recording Only" [AT7].
8. **Auto start changes the start time.** AudioCap and meeting-transcriber set `kAudioAggregateDeviceTapAutoStartKey` to true [AC-PT] [MT-AD]. The header says: "calling AudioDeviceStart with the aggregate device will wait until a tapped process begins receiving its first audio from any tapped applications. The composition must also include the private key" [SDK-AH]. Inference: with this key, the first IOProc call of a tap does not come at record start. This matters for the segment and timestamp model of 0004. See probe P3.

## 2. AudioCap (insidegui/AudioCap, BSD-2-Clause)

All facts are from commit `6f609e8` of 2025-08-07, the head of `main` on 2026-10-02 [AC].

### A1. Tap and aggregate setup

- Tap: `CATapDescription(stereoMixdownOfProcesses: [objectID])` with one process object [AC-PT]. There is no mono option.
- `tapDescription.uuid = UUID()`. `muteBehavior` is `.unmuted`, or `.mutedWhenTapped` when `muteWhenRunning` is true. The default of `muteWhenRunning` is false [AC-PT].
- AudioCap does not set `isPrivate`. The header does not state a default [SDK-CT]. Inference: the tap is public. The Apple sample has `isPrivate = false` in its UI default [APS-AT]. audiotee sets `isPrivate = true` [ATE-TM].
- Call order in `prepare(for:)` [AC-PT]:
  1. `AudioHardwareCreateProcessTap(tapDescription, &tapID)`.
  2. Read `kAudioHardwarePropertyDefaultSystemOutputDevice`, then its `kAudioDevicePropertyDeviceUID`.
  3. Build the aggregate dictionary.
  4. Read `kAudioTapPropertyFormat` from the tap.
  5. `AudioHardwareCreateAggregateDevice`.
  6. Later, in `run(on:)`: `AudioDeviceCreateIOProcIDWithBlock` on a serial `DispatchQueue` (QoS `.userInitiated`), then `AudioDeviceStart`.
- Aggregate dictionary [AC-PT]:

| Key | Value |
|---|---|
| `kAudioAggregateDeviceNameKey` | `"Tap-<pid>"` |
| `kAudioAggregateDeviceUIDKey` | new UUID string |
| `kAudioAggregateDeviceMainSubDeviceKey` | UID of the default **system** output device |
| `kAudioAggregateDeviceIsPrivateKey` | `true` |
| `kAudioAggregateDeviceIsStackedKey` | `false` |
| `kAudioAggregateDeviceTapAutoStartKey` | `true` |
| `kAudioAggregateDeviceSubDeviceListKey` | `[[kAudioSubDeviceUIDKey: outputUID]]` |
| `kAudioAggregateDeviceTapListKey` | `[[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: tapDescription.uuid.uuidString]]` |

- Note: AudioCap uses `kAudioHardwarePropertyDefaultSystemOutputDevice` (the header: "the output AudioDevice to use for system related sound from the alert sound to digital call progress" [SDK-AH]), not `kAudioHardwarePropertyDefaultOutputDevice` [AC-CU]. meeting-transcriber and the sudara gist use the default output device [MT699] [SG]. Inference: the two can differ when the user picks another alert device.
- Teardown order in `invalidate()` [AC-PT]: `AudioDeviceStop`, `AudioDeviceDestroyIOProcID`, `AudioHardwareDestroyAggregateDevice`, `AudioHardwareDestroyProcessTap`. meeting-transcriber uses the same order, with a drain of the write queue after `AudioDeviceDestroyIOProcID`, because "`AudioDeviceStop` does not synchronise against blocks already dispatched" [MT-TS]. The forum thread 825780 uses the same order for a rebuild [AF825780]. audiotee destroys the tap before the aggregate [ATE-TM].
- Other ways: the Apple sample and audiotee create the aggregate first and then set `kAudioAggregateDevicePropertyTapList` to the tap UID [APS-AD] [ATE-TM]. audiotee PR 14 (open) says that this path "silently fails" on macOS 26 with all-zero buffers, and that putting the tap list in the creation dictionary fixes it [ATE14]. The PR shows no measurement, and the Apple sample uses that path (unconfirmed).

### A2. Format

- AudioCap reads `kAudioTapPropertyFormat` (`'tfmt'`) into an `AudioStreamBasicDescription` before it creates the aggregate [AC-CU] [AC-PT]. The header: "This is the format of that data that will be accessible in any aggregate device that contains the tap" [SDK-AH].
- It makes an `AVAudioFormat` from that ASBD. In the IOProc it wraps `inInputData` with `AVAudioPCMBuffer(pcmFormat:bufferListNoCopy:deallocator: nil)` and calls `AVAudioFile.write(from:)` on the IOProc queue [AC-PT]. The file is a `.wav` in Application Support, opened with `commonFormat: .pcmFormatFloat32` and the `isInterleaved` flag of the tap format [AC-PT] [AC-PS].
- AudioCap does not state the channel count or interleaving. The Apple sample computes frames as `mDataByteSize / (mNumberChannels * sizeof(Float32))` [APS-AR]. The sudara gist reads `data[i * n_channels + ch]` as `float` [SG]. meeting-transcriber documents "Interleaved float32 (mono or stereo)" [MT-ARCH]. The forum thread reports "48,000 Hz, Float32, interleaved stereo" for a stereo tap [AF825780]. Inference: a mixdown tap gives one interleaved Float32 buffer with 1 or 2 channels, at the rate of the main sub-device. See probe P1.
- The sample rate can differ from the user's expectation. One user log shows the aggregate at 44100 Hz while the default output was at 48000 Hz, with a dock and a display connected [MT79].

### A3. Permission

- Info.plist: `NSAudioCaptureUsageDescription` = "Please allow access in order to capture audio from other apps." [AC-IP]. The README says: "This key is not listed in the Xcode dropdown, you have to enter it manually" [AC-RM].
- The app is sandboxed with `com.apple.security.device.audio-input` [AC-EN]. The Xcode project also sets `NSMicrophoneUsageDescription` = "Record audio" [AC-PBX].
- `AudioRecordingPermission.swift` uses private TCC functions when the build flag `ENABLE_TCC_SPI` is set (the default in `Main.xcconfig`) [AC-RP] [AC-XC]:
  - `dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)`.
  - `TCCAccessPreflight(CFString, CFDictionary?) -> Int` with service `"kTCCServiceAudioCapture"` and `nil`. AudioCap maps 0 to `.authorized`, 1 to `.denied`, and any other value to `.unknown`.
  - `TCCAccessRequest(CFString, CFDictionary?, (Bool) -> Void)` with the same service. The callback gives `granted`.
  - AudioCap reads the status again on each `NSApplication.didBecomeActiveNotification`.
- The UI: `.unknown` shows an "Allow" button that calls the request. `.denied` shows "Open System Settings" [AC-RV].
- Without the flag, AudioCap sets the status to `.authorized`, and the system asks at the first recording [AC-RP] [AC-RM]. This matches Apple: "The first time you start recording from an aggregate device that contains a tap, the system prompts you" [APS].
- What a denied tap does: AudioCap does not say. See section 1, item 6.
- The meaning of the preflight values 0 and 1 comes from AudioCap code only. Apple does not document these functions (unconfirmed).

### A4. Minimum macOS

- AudioCap: `MACOSX_DEPLOYMENT_TARGET = 14.4`. The README says "With macOS 14.4, Apple introduced new API" and gives no reason [AC-PBX] [AC-RM].
- Apple: the header marks `AudioHardwareCreateProcessTap` `API_AVAILABLE(macos(14.2))` [SDK-HT]. The Apple sample page says "ensure that you're using macOS 14.2 or later" [APS]. Its project deployment target is 14.2, and its app target is now 26.0 [APS-PBX]. The page metadata lists macOS 26.0, and its `TapConfig` uses `isProcessRestoreEnabled`, a macOS 26.0 property [APS] [APS-AT] [SDK-CT]. So the sample as published does not prove that the 14.2 path still builds.
- The macOS 14.4 release notes have no Core Audio tap item [AN144]. This research found no report of a tap failure on 14.2 or 14.3. The gap stays unconfirmed. Hardware check on 14.2 is still in 0006.

### A5. Process list

- AudioCap watches `NSWorkspace.runningApplications` with KVO. On each change it reads `kAudioHardwarePropertyProcessObjectList` [AC-PC]. It does not listen to the process list property. The Apple sample does [APS-M].
- For each process object it reads `kAudioProcessPropertyPID`. If the PID is a running app, it uses the app name, bundle ID, and bundle URL from `NSRunningApplication` [AC-PC].
- Otherwise it reads `kAudioProcessPropertyBundleID`, `proc_name`, and `proc_pidpath`, then the nearest bundle (section 1, item 3) [AC-PC].
- `audioActive` is `kAudioProcessPropertyIsRunning` [AC-CU]. The header has `kAudioProcessPropertyIsRunningOutput` for output only [SDK-AH].
- The header says that the process list holds "all client processes currently connected to the system" [SDK-AH]. `kAudioHardwarePropertyTranslatePIDToProcessObject` returns `kAudioObjectUnknown`, not an error, for an unknown PID [SDK-AH].

### A6. Issues

- AudioCap has GitHub issues turned off (`has_issues: false`) [AC-API]. There is one pull request, number 1 (open). Its thread has one user report of an empty file from a command-line tool, with no cause found [AC1]. AudioCap thus has no issue data on silence, Teams, Zoom, helper processes, output change, sample rate, or clipping.

## 3. Other tap users and Apple

### Which process plays the audio

| App | Process that plays the call | Evidence |
|---|---|---|
| Microsoft Teams (`com.microsoft.teams2`) | `Microsoft Teams ModuleHost`, inside `Microsoft Teams.app`, in one log | Measured log [MT699]. The working 5-PID tap of [MT84] had no ModuleHost, so the process that plays differs between installs or versions. Tap the whole bundle set, never one named helper. |
| Zoom (`us.zoom.xos`) | A process inside `zoom.us.app` (unconfirmed which one) | Inference: four Zoom recordings with the bundle-path tap were clean [MT671]. |
| Slack | Unconfirmed | One user says a Huddle "can be recorded manually by selecting Slack" [MT608]. |
| Google Chrome | Inference: the audio service process, a helper inside the app bundle | Not measured. Chromium runs the audio service out of process on macOS by default (`kAudioServiceOutOfProcess`) [CR]. meeting-transcriber says Chrome and Electron helpers "live inside their own bundle" [MT-ARCH]. |
| Safari | `com.apple.WebKit.GPU`, outside `Safari.app` | Measured [MT524] [MT-PR]. |
| FaceTime | `com.apple.avconferenced` (a daemon) | Measured on macOS 26.5.2 [MT-MID]. |

- More Teams detail: Teams installs a HAL driver, `MSTeamsAudioDevice.driver`. The reporter renamed it, and the tap was still silent. The real cause was the permission [MT79].
- Safari can change its output path during a call. WebKit plays the far end through a VoiceProcessingIO unit or through a plain output unit, and it can switch between them. In one 20-minute call the tap captured 1.24 s and then only zeros, with the correct PIDs in the tap [MT671]. The issue is open and not reproduced.
- One Teams setup had 5 PIDs in the tap: `MSTeams`, `Microsoft Teams WebView`, two `Microsoft Teams WebView Helper`, and `com.microsoft.teams2.notificationcenter` [MT84].

### Does `kAudioProcessPropertyBundleID` of a helper name the parent app?

- No source shows that it does. The header says only "the bundle ID of the process" [SDK-AH].
- meeting-transcriber matches the bundle ID `com.apple.avconferenced` against Core Audio process objects. That is the daemon's own ID [MT-MID]. Five `com.apple.WebKit.GPU` processes belonged to five different apps [MT671]. Inference: the property gives the helper's own bundle ID. A process with no bundle gives `noErr` and an empty string [MT-MID].
- Inference: to group helpers under an app, Dirigible needs the executable path (`proc_pidpath`) and, for system services, the responsible PID. The responsible PID function is private.

### Permission denied: silence or error

- Silence. `noErr`, a running IOProc, and zero samples [MT524] [MT79]. The audiotee README also warns that the tool can run "but never records anything" when the grant is missing [AT14]. The Apple sample does not say (section 2, A3).
- Some terminal apps do not show the prompt. The user must add the app by hand in the "System Audio Recording Only" section [AT7].

### Volume and samples above 1.0

- Pre- or post-volume: Nick Payne (audiotee) writes "Core Audio Taps captures audio pre-mixer, which means you get clean audio regardless of system volume", and also "I can't find anywhere this behaviour is documented" [ST]. Unconfirmed. See probe P6.
- Samples above 1.0: no source found. Inference: a Float32 mixdown of several loud processes can exceed 1.0, because nothing in the path is documented to clip. See probe P7.

### Start order with a Bluetooth headset

- meeting-transcriber opens the microphone first and the tap second. With the tap first, a Bluetooth headset that changed to its call profile left the tap with no IO callback for the whole recording: 9 failures in 30 starts, against 0 in 30 with the microphone first (measured by the maintainer, probe not published) [MT-ARCH].

## 4. Apple sample "Capturing system audio with Core Audio taps"

- The download is a git repository. Its last commit is "Minor update." after "Updates for macOS 26." [APS-GIT].
- The sample builds a `CATapDescription()` from UI fields: `name`, `processes`, `isPrivate`, `muteBehavior`, `isMixdown`, `isMono`, `isExclusive`, `deviceUID`, `stream` [APS-M]. It creates the aggregate with only a name and a UID, then adds sub-devices and taps through `kAudioAggregateDevicePropertyFullSubDeviceList` and `kAudioAggregateDevicePropertyTapList` [APS-M] [APS-AD].
- It sets a live tap description through `kAudioTapPropertyDescription` [APS-AT].
- It listens to `kAudioHardwarePropertyProcessObjectList`, `kAudioHardwarePropertyTapList`, and `kAudioHardwarePropertyDevices` on the system object, and to `kAudioProcessPropertyIsRunning` per process [APS-M] [APS-AP].
- It records each input stream to a CAF file with `ExtAudioFileCreateWithURL(..., kAudioFileCAFType, &format, ...)` and `ExtAudioFileWriteAsync` in a C IOProc. The format is the stream's `kAudioStreamPropertyVirtualFormat` [APS-AR].
- Info.plist: `NSAudioCaptureUsageDescription` = "This app requires access to application audio". The app is sandboxed with `com.apple.security.device.audio-input` [APS-IP].
- Mute modes in the header: `CATapUnmuted` ("captured by the tap and also sent to the audio hardware"), `CATapMuted`, and `CATapMutedWhenTapped` [SDK-CT].

## 5. Hindenburg PRO and calls

- **How the user records a call on Mac.** Arm a track for the microphone. Arm a second track for the guest, set Record Monitor to On, and set its source to "Other Applications > Stereo". In the call app, "set the Speaker to Hindenburg". The article uses Skype and says it "works the same way for Zoom and any other third party Voice Over IP application" [HK]. The result is two tracks: the local microphone and the remote app.
- **The Hindenburg Audio Device.** "Route system and application audio directly into your session. Record Zoom, Google Meet, browsers or streaming sources with precision and control" [HFH]. It is a virtual audio device that replaced Soundflower in Journalist Pro for macOS (article of 2021-06-29) [PVC]. Build 2604 of PRO 2.02 "Updated Hindenburg Device on macOS to avoid ticking sound when recording from YouTube" [HR2604].
- **No built-in tap capture.** The release notes up to PRO 2.05 build 2752 have no app-capture or process-tap item. They mention the Hindenburg Device only in build 2604 [HR]. Inference: PRO 2.x still records other apps through its virtual device.
- **Call preset.** Journalist 1.21 had a "Call Recorder" for Skype. It recorded "two mono tracks": a transmit track (your voice) and a receive track (the guest). It could use "direct input" for your voice, because the Skype copy of your voice was gated and not in full quality. The user could play clips to the guest during the call [HJ p. 20-23]. This feature stopped with Skype 8 (capture.md, podcast-features.md F06). PRO 2.x has no call preset in its pages. "It's as easy as opening up a new recording track" [HT].
- **Phone calls.** Hindenburg cannot record a phone call directly. It recommends a mixer with a mix-minus feed, or a VoIP service [HK2].
- **Headphones.** No Hindenburg source found gives headphone advice for calls (unconfirmed). Rogue Amoeba advice is in capture.md section 6.
- **Levels over 0 dBFS.** No Hindenburg source found describes a clip indicator on record (unconfirmed). The 1.21 guide says "The Meter shows QPPM" and also lists a loudness meter and a BBC meter [HJ]. Auto Level sets dialogue peaks to "-9 dB on a QPPM scale" [HFH].
- **Recording file format.** Under "capture audio" (studio, field, "Zoom calls. Web audio."): "All audio is converted to uncompressed 64-bit floating point WAV for precision and consistent quality across sources" [HFH]. Imports are also converted "to uncompressed 64-bit floating point WAV for headroom and precision" [HFH]. The Journalist 1.21 guide said "all sessions are 16 bit" [HJ]. Inference: PRO 2.x records to 64-bit float WAV, so levels over 0 dBFS from an app source survive in the file.

## 6. A tap that dies during a session

- Apple forum thread 825780 (macOS 26.5 beta, MacBook Air M2, no reply): a private global tap, anchored on the default output UID, went to "exactly `0.0f`" in every buffer while the IOProc kept its normal cadence and timestamps. Periods lasted from 53 s to 16 minutes, and some recovered on their own [AF825780].
- The poster lists suspects: a sample-rate change of the output device, AirPods sleep and wake, and long uptime (unconfirmed).
- Workaround from the thread: a full teardown and rebuild of tap, aggregate, and IOProc. "Restarting the IOProc alone or recreating only the aggregate device is not reliable" [AF825780].
- The poster says that `kAudioProcessPropertyIsRunningOutput` is not a test for real samples [AF825780].
- Inference: the 0006 warning "zero samples while `IsRunningOutput` is 1" cannot tell a denied permission from a dead tap. The fix differs: the user opens Settings for a denied permission, and the app rebuilds the tap for a dead tap.
- A floor is not zero. In [MT699] the dead track carried a constant floor near -98.5 dBFS, not exact zeros. A detector that counts exact zeros missed it [MT699].

## 7. Open questions for a probe on this Mac (macOS 15.7.9, Intel x86_64)

- **P1. Tap format.** For a mono and a stereo mixdown, print the `kAudioTapPropertyFormat` ASBD: rate, flags, channels, interleaving. Print the IOProc buffer list too. Does the rate follow the main sub-device when the user changes the default output rate?
- **P2. Anchor device.** A process plays to device B. The default output is device A. Compare an aggregate anchored on A with one anchored on B. Use one output-only device and one device with input and output. This decides the main sub-device rule of 0006.
- **P3. Auto start.** With `kAudioAggregateDeviceTapAutoStartKey` true and false: does `AudioDeviceStart` block? When does the first IOProc call come, if the app is silent at start? What are the host time and sample time of the first buffer?
- **P4. Live process change.** Does a set of `kAudioTapPropertyDescription` with a new process list add a helper to a running tap with no gap and no rebuild?
- **P5. Permission.** Does the prompt appear for the ad-hoc signed app bundle? With permission denied, does the tap give exact zeros from the first buffer? Does a Screen Recording grant alone unlock it on macOS 15?
- **P6. Volume.** Change the system output volume during a tap. Does the tap level change?
- **P7. Over 1.0.** Mix two full-scale processes into one mixdown tap. Do samples exceed 1.0?
- **P8. Private tap.** Does `isPrivate` true change any behavior? Does the tap still appear in `kAudioHardwarePropertyTapList` of another process?
- **P9. Creation path.** Tap list in the creation dictionary against a later set of `kAudioAggregateDevicePropertyTapList`: do both give samples on macOS 15?
- **P10. Rebuild.** After a stop, does Stop, DestroyIOProcID, DestroyAggregateDevice, DestroyProcessTap, then a new tap and aggregate, give samples again with a new clock base?
- **P11. Start order.** With a Bluetooth headset, open the microphone first, then the tap, and the reverse. Count starts with no IO callback.
- **P12. Helper set.** During a real Teams, Zoom, Slack, Chrome, and Safari call, list each process object with its bundle ID, `proc_pidpath`, and `kAudioProcessPropertyIsRunningOutput`. Does `kAudioProcessPropertyBundleID` of each helper name the helper or the app?

## Sources

- [SDK-AH] macOS SDK 26.2, `CoreAudio.framework/Headers/AudioHardware.h`: `kAudioAggregateDeviceIsPrivateKey`, `kAudioAggregateDeviceIsStackedKey`, `kAudioAggregateDeviceTapAutoStartKey`, `kAudioSubTapDriftCompensationKey`, `kAudioTapPropertyFormat`, `kAudioHardwarePropertyProcessObjectList`, `kAudioHardwarePropertyTranslatePIDToProcessObject`, `kAudioProcessProperty*`.
- [SDK-HT] macOS SDK 26.2, `CoreAudio.framework/Headers/AudioHardwareTapping.h`.
- [SDK-CT] macOS SDK 26.2, `CoreAudio.framework/Headers/CATapDescription.h`.
- [AC] insidegui/AudioCap, commit `6f609e8ad1b1e11fa0e8edbe91864cb099f00de3` (2025-08-07): https://github.com/insidegui/AudioCap/tree/6f609e8ad1b1e11fa0e8edbe91864cb099f00de3
- [AC-PT] `AudioCap/ProcessTap/ProcessTap.swift` at [AC].
- [AC-CU] `AudioCap/ProcessTap/CoreAudioUtils.swift` at [AC].
- [AC-PC] `AudioCap/ProcessTap/AudioProcessController.swift` at [AC].
- [AC-RP] `AudioCap/ProcessTap/AudioRecordingPermission.swift` at [AC].
- [AC-RV] `AudioCap/RootView.swift` at [AC].
- [AC-PS] `AudioCap/ProcessSelectionView.swift` at [AC].
- [AC-IP] `AudioCap/Info.plist` at [AC].
- [AC-EN] `AudioCap/AudioCap.entitlements` at [AC].
- [AC-XC] `AudioCap/Config/Main.xcconfig` at [AC].
- [AC-PBX] `AudioCap.xcodeproj/project.pbxproj` at [AC].
- [AC-RM] `README.md` at [AC].
- [AC-API] GitHub API `repos/insidegui/AudioCap`, read 2026-10-02: `has_issues: false`, license BSD-2-Clause.
- [AC1] insidegui/AudioCap pull request 1: https://github.com/insidegui/AudioCap/pull/1
- [APS] Apple, "Capturing system audio with Core Audio taps": https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps
- [APS-GIT] The sample download `CapturingSystemAudioWithCoreAudioTaps.zip` (https://docs-assets.developer.apple.com/published/02fe64305fe7/CapturingSystemAudioWithCoreAudioTaps.zip), git commit `9c60e5f`.
- [APS-M] `AudioTapSample/Model.swift` in [APS-GIT].
- [APS-AT] `AudioTapSample/AudioTap.swift` in [APS-GIT].
- [APS-AD] `AudioTapSample/AggregateDevice.swift` in [APS-GIT].
- [APS-AP] `AudioTapSample/AudioProcess.swift` in [APS-GIT].
- [APS-AR] `AudioTapSample/AudioRecorder.mm` in [APS-GIT].
- [APS-IP] `AudioTapSample/Info.plist` and `AudioTapSample.entitlements` in [APS-GIT].
- [APS-PBX] `AudioTapSample.xcodeproj/project.pbxproj` in [APS-GIT].
- [AN144] Apple, macOS Sonoma 14.4 release notes: https://developer.apple.com/documentation/macos-release-notes/macos-14_4-release-notes
- [AF825780] Apple Developer Forums thread 825780, "AudioHardwareCreateProcessTap delivers all-zero buffers while system audio is audible": https://developer.apple.com/forums/thread/825780
- [ATE-TM] makeusabrew/audiotee, commit `56ac954369a09318e46b88a6eec33c2d2b0d32a3`, `Sources/AudioTeeCore/Core/AudioTapManager.swift`: https://github.com/makeusabrew/audiotee/blob/56ac954369a09318e46b88a6eec33c2d2b0d32a3/Sources/AudioTeeCore/Core/AudioTapManager.swift
- [AT7] makeusabrew/audiotee issue 7, maintainer comment on the permission list: https://github.com/makeusabrew/audiotee/issues/7
- [ATE14] makeusabrew/audiotee pull request 14: https://github.com/makeusabrew/audiotee/pull/14
- [AT14] makeusabrew/audiotee README, "Permissions": https://github.com/makeusabrew/audiotee/blob/56ac954369a09318e46b88a6eec33c2d2b0d32a3/README.md
- [SG] sudara, Core Audio tap example gist (updated 2026-04-28): https://gist.github.com/sudara/34f00efad69a7e8ceafa078ea0f76f6f
- [ST] Nick Payne, "Recording system audio in Electron on macOS" (2025-10-24): https://stronglytyped.uk/articles/recording-system-audio-electron-macos-approaches
- [MT] pasrom/meeting-transcriber (MIT), commit `37616f58edeb5dc8ee11d5981aaef5ca8c769f95`: https://github.com/pasrom/meeting-transcriber/tree/37616f58edeb5dc8ee11d5981aaef5ca8c769f95
- [MT-PR] `tools/audiotap/Sources/ProcessResponsibility.swift` at [MT].
- [MT-AD] `tools/audiotap/Sources/AppAudioCapture+AggregateDescription.swift` at [MT].
- [MT-TS] `tools/audiotap/Sources/AppTapSession.swift` at [MT].
- [MT-MID] `app/MeetingTranscriber/Sources/MicInputDetector.swift` at [MT].
- [MT-ARCH] `docs/architecture-macos.md` at [MT], sections "Capture", "Start order", and "Safari support".
- [MT-CL] `CLAUDE.md` at [MT], section "Critical Notes".
- [MT79] pasrom/meeting-transcriber issue 79: https://github.com/pasrom/meeting-transcriber/issues/79
- [MT84] pasrom/meeting-transcriber issue 84: https://github.com/pasrom/meeting-transcriber/issues/84
- [MT524] pasrom/meeting-transcriber issue 524: https://github.com/pasrom/meeting-transcriber/issues/524
- [MT608] pasrom/meeting-transcriber issue 608: https://github.com/pasrom/meeting-transcriber/issues/608
- [MT671] pasrom/meeting-transcriber issue 671: https://github.com/pasrom/meeting-transcriber/issues/671
- [MT699] pasrom/meeting-transcriber issue 699: https://github.com/pasrom/meeting-transcriber/issues/699
- [CR] Chromium `content/public/common/content_features.cc`, `kAudioServiceOutOfProcess`, commit `47452ccdc9f64cde5f91144c982031733d4b2c40`: https://chromium.googlesource.com/chromium/src/+/47452ccdc9f64cde5f91144c982031733d4b2c40/content/public/common/content_features.cc
- [HK] Hindenburg support, "Record internal sound on Mac - Zoom, Skype, etc.": https://hindenburg.uservoice.com/knowledgebase/articles/1982517-record-internal-sound-on-mac-zoom-skype-etc
- [HK2] Hindenburg support, "How do I record a phone call or a remote interview in Hindenburg?": https://hindenburg.uservoice.com/knowledgebase/articles/1909561-how-do-i-record-a-phone-call-or-a-remote-interview
- [HFH] Hindenburg PRO feature highlights: https://hindenburg.com/academy/lessons/feature-highlights/
- [HT] Hindenburg PRO tracking: https://hindenburg.com/hindenburg-pro-features/tracking/
- [HR] Hindenburg PRO release notes: https://hindenburg.com/support/release-notes/hindenburg-series/
- [HR2604] Hindenburg PRO 2.02 build 2604 release notes: https://hindenburg.com/release-notes-hindenburg-pro_version-2/pro-v2_02-build-2604/
- [HJ] Hindenburg Journalist 1.21 user guide, pages 20 to 23 and the session note: https://www.willyurman.com/teaching/handouts/Hindenburg_Journalist.pdf
- [PVC] Allan Tépper, "Hindenburg replaces Soundflower with its own virtual audio device", ProVideo Coalition, 2021-06-29: https://www.provideocoalition.com/hindenburg-replaces-soundflower-with-its-own-virtual-audio-device/
