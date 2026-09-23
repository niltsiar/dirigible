# 0006. App audio: Core Audio process taps, one private aggregate per tap

- Status: accepted
- Date: 2026-09-24

## Context

R12 asks to record the audio of another app, for example a Teams, Slack, or Zoom call, on its own track. R4 forbids a macOS aggregate device for multi-source recording. The research is in `docs/research/capture.md` section 5. The options are Core Audio process taps (`AudioHardwareCreateProcessTap`, macOS 14.2 and later) and ScreenCaptureKit audio (macOS 13 and later).

A process tap can only be read through an aggregate device. The user confirmed on 2026-09-23 that R4 allows this: the aggregate is private, the user never sees it, and it holds one tap. It never combines microphones.

## Decision

- Use Core Audio process taps. The tap aggregate is a device like any other, so it uses the IOProc, ring, writer, and segment path of 0004 without changes.
- One tap and one private aggregate device per app source. Set `privateTap` and `.unmuted`, so the user still hears the call.
- The main sub-device of the tap aggregate is the default output device, so the output device clocks the tap. When that device goes away or the default output changes, rebuild the aggregate on the new output device and start a new segment (0004). The guest track keeps recording.
- The user picks an app, not a process. Tap every process whose executable is inside the app bundle. Watch `kAudioHardwarePropertyProcessObjectList` and update the tap when helper processes start or stop. Call apps often play audio from a helper process.
- Add `NSAudioCaptureUsageDescription` to `Support/Info.plist` in English and to `es.lproj/InfoPlist.strings` in Spanish. `AppBundleTests` checks both.
- No public API reads the System Audio Recording permission. A denied tap gives silence. If a tap gives only zero samples for some seconds while the app plays audio (`IsRunningOutput` is 1), show a warning with a link to the privacy settings.
- On macOS 14.0 and 14.1, which have no process taps, the app source is not available. The app tells the user to update macOS.
- Release 2 builds this (see `docs/requirements/releases.md`).

## Consequences

- R12 needs macOS 14.2 or later. The rest of the app still runs on macOS 14.0.
- The header says 14.2. A sample project says 14.4. A hardware check on 14.2 and 14.3 decides the real floor.
- Hardware checks: a real Teams call, a Zoom call, a Slack huddle, and a meeting in Chrome and Safari; the permission prompt for the ad-hoc signed app; the tap does not change the output device, its rate, or its latency; a change of the output device during a recorded call.

## Alternatives considered

- **ScreenCaptureKit audio.** Kept as the fallback if taps cannot capture a call app. It needs the Screen Recording permission, which macOS 15 asks again every month, and it gives timestamps on a different clock.
- **A virtual audio device (a driver, like Hindenburg's).** Rejected. It needs a driver install and an admin password, and the user must route the call app to it.
- **Voice processing input.** Rejected in 0004.
