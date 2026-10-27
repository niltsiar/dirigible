# AUSoundIsolation for the clip render (R8, F35)

Date: 2026-10-13, with probes of 2026-10-27

This note keeps the facts about AUSoundIsolation that decision 0054 uses. Host of each probe: macOS 15.7.9, Intel (x86_64). The probes drive the raw unit through ctypes on AudioToolbox, with no build.

## Facts

- **Unit.** AUSoundIsolation of Apple (`aufx`, `vois`, `appl`), the Voice model (`kAUSoundIsolationSoundType_Voice`). `auval` passes from 11.025 to 192 kHz and from 1 to 8 channels. No license and no dependency.
- **What it removes.** It isolates voice. White noise goes from -24.8 dBFS to -157 dBFS at wet 100, a 300 Hz tone goes to 0, and 60 Hz hum goes 32 dB under the voice. So it also removes hum and music.
- **Latency.** The unit delays its output by 56.35 ms mono (2705 frames) and 76.35 ms stereo at 48 kHz. The latency changes with the channel count, so the render reads `kAudioUnitProperty_Latency` after the format is set.
- **Wet/dry mix.** The mix is linear: the reduction of noise with no voice is -20 log10(1 - wet / 100) dB, and wet 100 gives -102 dBFS. On 10 s of seeded noise at 48 kHz, wet values for 6, 12, 18, 24, and 30 dB cut 6.00, 12.00, 18.00, 24.00, and 30.00 dB (probe of 2026-10-27).
- **Null.** At wet 0 the output equals the input within 1.5e-8 after the latency trim.
- **Stereo.** With 2 channels the unit applies one mask and moves no audio between channels.
- **Repeatability.** Two new instances at 12 dB give the same output for a hot voice of 422,868 frames, pulled in calls of 4096 frames: the maximum difference is 0, and both peaks are 1.3253204 (probe of 2026-10-27).
- **Pull size.** The output depends on the size of the render calls: a first call of 2048 or 3200 frames, or calls of 8192 frames, change the output. So the render pulls 4096 frames at each call.
- **Speed.** It renders at about 8 times real time.

## Not checked

- macOS 14, macOS 26, and Apple silicon.
- Voice quality on real speech at each amount (a listen).

## Sources

- SDK headers `AUComponent.h` and `AudioUnitParameters.h`.
- Apple, Final Cut Pro User Guide, "Enhance audio": https://support.apple.com/guide/final-cut-pro/enhance-audio-verc1fab873/mac
