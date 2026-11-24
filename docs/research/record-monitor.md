# Record monitor: how Hindenburg PRO, Logic Pro, and GarageBand let the user hear an input

Date: 2026-10-10

Question: how do the reference apps let the user hear the input of a track in the output (input monitoring)? Which control turns it on, is it automatic or manual, what do the apps say about latency, and how do they guard against feedback from speakers? Release 3 run 1 (F02 part, tester items B1.5 and B2.10) uses the answers.

## 1. Hindenburg PRO

- Control: "Right-click on the Arm Rec Button to choose monitor On / Off" [HB-RM]. The control is in a context menu of the arm button, not a separate button. A tester asked for a visible button because of this.
- What it does: "With Record Monitor On you can listen to the incoming signal on a track BEFORE begin recording." [HB-RM]. The page does not say whether the monitor continues during a take (unconfirmed). A tester asked to hear the input while recording.
- Mode: manual, per track. No source shows an automatic mode.
- Track header: the 1.21 guide lists name, volume, pan, record, monitor, mute, solo, and effects [HJ] p. 9.
- Latency: the 1.21 guide warns about latency on a microphone signal [HJ] p. 19. This run did not read the PDF again (the text did not extract). The claim comes from `document-window.md` section 8.
- Feedback guard: no Hindenburg source found (unconfirmed).
- Calls: Hindenburg tells the user to set Record Monitor On for the guest track, because the call app sends its sound to the Hindenburg virtual device and not to the speakers (`process-taps.md` section 5, [HK]). Inference: Dirigible taps the call with `CATapUnmuted` (`mixdown` in `Sources/DirigibleAudio/Capture/AppTap.swift`), so the call app still plays to the output, and an app track needs no monitor.

## 2. Logic Pro for Mac

- Control: "Click the Input Monitoring button (with the "I" icon) in the track header." "Click the Input Monitoring button again to turn off input monitoring for the track." [LP-IM]. The button works on a track that is not record-enabled [LP-SM].
- Modes: Logic has an automatic mode and a manual mode.
  - Automatic: with Software Monitoring on (a Core Audio preference), a record-enabled track with an input plays its input [LP-SM]. "If Auto Input Monitoring is turned on, you will hear the input signal only during the actual recording." "If Auto Input Monitoring is turned off, you will always hear the input signal." [LP-SM].
  - Manual: the I button. With it on, "the Record Enable button and the Auto Input Monitoring feature do not affect software monitoring" [LP-IM].
  - Punch recording: "you should use Auto Input Monitoring rather than the Input Monitoring buttons." [LP-IM].
- Latency: "Input monitoring always involves some latency." "The amount of latency depends on the audio hardware and the driver settings." "In certain configurations, it may be best not to turn on input monitoring, to obtain the best possible timing." [LP-IM]. The 9.1.6 manual tells the user to route the input directly to the headphones in that case [LP-SM]. The 2026 article: "smaller buffer sizes reduce input monitoring latency"; Bluetooth headphones or speakers as the output "also results in latency", so use them "for mixing or listening only" [LP-LAT].
- Feedback guard: no Logic source found (unconfirmed).
- Version note: the quotes of [LP-IM] come from the Logic Pro 10.1 help page, and [LP-SM] from the 9.1.6 manual. The current guide page [LP-IM-NOW] has the same title, but its text did not load. [LP-LAT] is dated 2026-05-27.

## 3. GarageBand for Mac

- Control: "Click the Monitoring button ... in the track header." The Smart Controls inspector has the same button [GB-BR]. "Click the Monitoring button again to turn off input monitoring for the track." [GB-IM].
- Mode: manual, per track. "You can turn on the Monitoring button on an unselected track to hear its input signal whenever you select the track." [GB-BR]. Inference: the monitor of a track that is not selected waits until the user selects it.
- Latency: no GarageBand source found (unconfirmed).
- Feedback: "When monitoring is turned on, your computer can pick up output from your speakers or monitors, causing unwanted feedback." "Using headphones rather than speakers to listen to your projects can help eliminate feedback." [GB-IM]. With the built-in microphone, "monitoring is turned off for all Electric Guitar tracks to avoid unwanted noise." [GB-IM]. The guitar page says to choose Off "to avoid feedback" with a microphone, On with headphones, and Off "If feedback occurs" [GB-GTR].
- Feedback guard: older GarageBand versions have a Monitor menu item "On with Feedback Protection". Apple says it "may give feedback warning messages when there is no feedback occurring", and the fix is to choose "On instead of On with Feedback Protection" [GB-FP] (2023-08-21). Whether the protection turns the monitor off is unconfirmed: only the warning is in a source.

## 4. Summary

| | Hindenburg PRO | Logic Pro | GarageBand |
|---|---|---|---|
| Control | Context menu of the arm button | "I" button in the track header | Monitoring button in the track header |
| Auto or manual | Manual | Both: arm plus Software Monitoring (auto), Auto Input Monitoring for punch-in, and the manual I button | Manual |
| Needs arm | Unconfirmed (the control is on the arm button) | No | No |
| During a take | Unconfirmed | Yes | Yes (inference: the guide says "as you play and record") |
| Latency note | Yes (secondary, not read again) | Yes, with buffer size, Bluetooth, and direct monitoring advice | None found |
| Speaker guard | None found | None found | Text advice; "Feedback Protection" warning in older versions; guitar tracks with the built-in microphone start with the monitor off |

Inferences for Dirigible (not decisions; the plan decides):

- A manual button per track is the common behavior. No reference app makes the monitor depend on the toolbar meter toggle.
- Every app warns about latency or feedback in text only. No source shows an app that blocks the monitor on built-in speakers. A block on the built-in speakers (F43) is our own guard, with no reference behavior. It is safe: the built-in microphone and the built-in speakers of a Mac are close together.

## 5. Open questions (probes, for the lead)

Decision 0044 answers these questions with probes P1 to P9.

- The latency from the built-in microphone, and from a USB microphone, to the headphones: a probe computes it from the input and output time stamps and the device latencies, with no loopback cable.
- The clock drift between a USB input and the built-in output, in ppm, over 30 min. Whether the built-in input and output share one clock domain (`kAudioDevicePropertyClockDomain`).
- Whether an output client (a second `AVAudioEngine` or an output IOProc) follows a change of the default output, and how long the headphone unplug takes to reach the data source listener.

## Sources

- [HB-RM] Hindenburg support, "Record monitor on / off": https://hindenburg.uservoice.com/knowledgebase/articles/1911799-record-monitor-on-off
- [HJ] Hindenburg Journalist 1.21 user guide (Hindenburg Systems), hosted by willyurman.com: https://www.willyurman.com/teaching/handouts/Hindenburg_Journalist.pdf
- [HK] Hindenburg support, "Record internal sound on Mac - Zoom, Skype, etc." (read in `docs/research/process-taps.md` section 5): https://hindenburg.uservoice.com/knowledgebase/articles/1982517-record-internal-sound-on-mac-zoom-skype-etc
- [LP-IM] Logic Pro 10.1 help, "Turn on input monitoring for audio tracks": https://help.apple.com/logicpro/mac/10.1/en.lproj/lgcpbfbefa96.html
- [LP-IM-NOW] Logic Pro for Mac User Guide, "Use input monitoring with tracks": https://support.apple.com/guide/logicpro/lgcpbfbefa96/mac
- [LP-SM] Logic Pro 9.1.6 user manual, "Enabling Software Monitoring for Recording": https://help.apple.com/logicpro/mac/9.1.6/en/logicpro/usermanual/chapter_14_section_5.html
- [LP-LAT] Apple Support 105040, "Manage input monitoring latency in Logic Pro for Mac" (2026-05-27): https://support.apple.com/105040
- [GB-BR] GarageBand for Mac User Guide, "Before recording audio": https://support.apple.com/guide/garageband/gbnd4c2cc43e/mac
- [GB-IM] GarageBand for Mac User Guide, "Use input monitoring": https://support.apple.com/guide/garageband/gbnd4bc15233/mac
- [GB-GTR] GarageBand for Mac User Guide, "Set an input source for guitar": https://support.apple.com/guide/garageband/gbndbbe1df77/mac
- [GB-FP] Apple Support 101810, "GarageBand: Feedback Protection may be very sensitive with some USB mics" (2023-08-21): https://support.apple.com/en-ca/101810
