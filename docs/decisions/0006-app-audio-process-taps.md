# 0006. App audio: Core Audio process taps, one private aggregate per tap

- Status: accepted
- Date: 2026-09-24
- Amended: 2026-10-02. The processes of an app are each process object whose bundle ID is the app ID or starts with the app ID and a dot, or whose executable is inside the app bundle. A helper that starts rebuilds the tap and its aggregate into a new segment, because a live update of the tap process list gives `!hog`. The aggregate has auto start false. The silence warning comes after 5.0 s of zeros while a matched process plays, with rebuilds at the warning, 10 s after it, and 40 s after it (see 0030).
- Amended: 2026-10-28, run `2026-10-27-armed-app-track`. The grant check runs after each attach of a monitor app writer: the first attach and each rebuild. It makes a throwaway tap of the same processes, with the same description and no aggregate. Then it sets `kAudioTapPropertyDescription` of that tap to the same description. Probe P1 measured the set only in form 1, with a stereo mixdown of one process, on macOS 15.8.1. No probe measured a mono mixdown, a tap of two or more processes, or another macOS version. With the grant, the set gives noErr; with no grant, it gives `'!hog'`. The status is the same while the recorded tap runs, and the recorded tap gets no gap. `'!hog'` shows **No access** until a noErr check or a sample that is not zero; another status changes nothing. The recorded tap never gets the set. A take writer runs no check, so a take shows only the silence warning. Before an answer to the prompt, the set shows the prompt and waits for the answer. So the check runs only after the attach.

## Context

R12 asks to record the audio of another app, for example a Teams, Slack, or Zoom call, on its own track. R4 forbids a macOS aggregate device for multi-source recording. The research is in `docs/research/capture.md` section 5. The options are Core Audio process taps (`AudioHardwareCreateProcessTap`, macOS 14.2 and later) and ScreenCaptureKit audio (macOS 13 and later).

A process tap can only be read through an aggregate device. The user confirmed on 2026-09-23 that R4 allows this: the aggregate is private, the user never sees it, and it holds one tap. It never combines microphones.

## Decision

- Use Core Audio process taps. The tap aggregate is a device like any other, so it uses the IOProc, ring, writer, and segment path of 0004 without changes.
- A mono guest track uses a mono mixdown tap (`CATapDescription(monoMixdownOfProcesses:)`), and a stereo guest track uses a stereo mixdown tap.
- One tap and one private aggregate device per app source. Set `privateTap` and `.unmuted`, so the user still hears the call.
- The main sub-device of the tap aggregate is the output device of the tapped process (`kAudioProcessPropertyDevices`), or the default output device if the process reports none. Set `kAudioSubTapDriftCompensationKey` to true on the sub-tap. When the main sub-device goes away or the process changes its output, rebuild the aggregate on the new device and start a new segment (0004). The guest track keeps recording.
- The user picks an app, not a process. Tap every process of the app: its bundle ID is the app ID or starts with the app ID and a dot, or its executable is inside the app bundle (0030). Watch `kAudioHardwarePropertyProcessObjectList` and rebuild the tap when a helper process starts (0030). Call apps often play audio from a helper process.
- Add `NSAudioCaptureUsageDescription` to `Support/Info.plist` in English and to `es.lproj/InfoPlist.strings` in Spanish. `AppBundleTests` checks both.
- No public API reads the System Audio Recording permission. A denied tap gives silence. If a tap gives only zero samples for 5.0 s while the app plays audio (`IsRunningOutput` is 1), show a warning with a link to the privacy settings, and rebuild the tap (0030). A monitor app writer also runs the grant check of the 2026-10-28 amendment, which shows **No access** before this warning.
- On macOS 14.0 and 14.1, which have no process taps, the app source is not available. The app tells the user to update macOS.
- Release 2 builds this (see `docs/requirements/releases.md`).

## Consequences

- R12 needs macOS 14.2 or later. The rest of the app still runs on macOS 14.0.
- The header says 14.2. A sample project says 14.4. A hardware check on 14.2 and 14.3 decides the real floor.
- Hardware checks: a real Teams call, a Zoom call, a Slack huddle, and a meeting in Chrome and Safari; the permission prompt for the ad-hoc signed app; the tap does not change the output device, its rate, or its latency; a change of the output device during a recorded call; Teams on a USB headset while the default output is the built-in speakers, for 30 minutes.

## Alternatives considered

- **ScreenCaptureKit audio.** Kept as the fallback if taps cannot capture a call app. It needs the Screen Recording permission, which macOS 15 asks again every month, and it gives timestamps on a different clock.
- **A virtual audio device (a driver, like Hindenburg's).** Rejected. It needs a driver install and an admin password, and the user must route the call app to it.
- **Voice processing input.** Rejected in 0004.
