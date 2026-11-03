# Recording offset in other editors

Date: 2026-11-03

Question: does each editor use the latency that the audio device reports to place a take against playback? Which manual setting exists?

This note supports decision 0070 (PA5). A claim that no primary source confirms has the mark "(unconfirmed)". A sentence that starts with "Inference:" is our reading of the sources.

## Findings

| Editor | Uses reported latency | Manual setting: name, default, unit, place | Auto calibration | Source |
|---|---|---|---|---|
| Logic Pro | Not stated | "Recording Delay" slider. Default and unit not stated. Settings > Audio > Devices. | I/O utility "Latency Detection (Ping)": loopback for hardware inserts. Offset in samples. Not for take placement. | S1, S2 |
| GarageBand | Not stated | None documented | None found | S3 |
| Audacity 3.7.9 | No. Placement uses only the manual value. `mLastRecordingOffset` (from PortAudio) is set but never read. | "Latency compensation", key `/AudioIO/LatencyCorrection`, default -130, ms. Preferences > Devices. | Beta forum macro: plays 5 clicks, records them, averages, sets the value. Not in the app code. | S4, S5 |
| Audacity 4.0.2 | Only if "Automatic" is on: offset = -(input latency + output latency) from PortAudio | "Latency compensation", key `/AudioIO/LatencyCompensation`, default -130, ms. Preferences > Audio > Buffer and latency. "Automatic" default: UI off, engine unconfirmed. | None in code | S6 |
| Pro Tools | Not stated for Core Audio or ASIO. Two options for Avid HD interfaces (HDX, HD Native): "Compensation for Input/Output Delays After Record Pass". | "H/W Insert Delay": ms per input, hardware inserts only. Setup > I/O > H/W Insert Delay. Default not stated. | Manual loopback procedure: bus track 1 to track 2, record, measure | S7 |
| Reaper | Yes: "Use audio driver reported latency" moves recordings back by the reported value | Manual input and output offsets, samples. Preferences > Audio > Recording. Defaults not stated. | None in preferences. ReaInsert "Automatic device latency adjustment" for hardware inserts. | S8, S9 |
| Hindenburg PRO | Not stated | None found | None found | S10 |

## Notes

- Only Reaper and Audacity 4 document use of the driver value. Audacity 4 makes it opt-in.
- Reaper wiki: for one interface, the reported value was "nowhere near the right number" (unconfirmed: the archive copy was not read again). The wiki tells the user to measure and enter the result by hand.
- Audacity 3.x moves the new take back by one fixed offset after recording.

## Check of the sources

A second reader checked three rows against the source on 2026-11-03.

- Audacity 3.7.9: confirmed. `libraries/lib-audio-devices/AudioIOBase.cpp` has `DoubleSetting AudioIOLatencyCorrection{ L"/AudioIO/LatencyCorrection", -130.0 }`. In `libraries/lib-audio-io/AudioIO.cpp`, `mLastRecordingOffset` is only set (lines 266, 908, 2996, and 3000), and that file never reads it (tag Audacity-3.7.9).
- Reaper: confirmed. User guide 7.84, page 76: "Whether to use audio driver reported latency: this automatically adjusts media positioning to compensate for the audio driver's reported latency. There are also options for this to be manually adjusted. Beginners especially should leave these at their default settings."
- Logic Pro: confirmed. The Devices settings page [S1]: "Recording Delay slider: Delays the recording of audio by a certain fixed value, helping you to compensate for any delays that are caused by the audio driver. Note: You should not normally need to touch this setting." Inference: Logic uses the latency that the driver reports by default, and the slider corrects the rest.
- The Cockos wiki quote "nowhere near the right number" [S9]: not checked. No decision uses it.

## Open questions

- Inference: Logic Pro and GarageBand may use the driver value. No Apple page says so, and no probe ran.
- Logic Pro "Recording Delay": unit and default are not in the Apple guide.
- Pro Tools: no source gives the placement rule for non-HD interfaces.
- Reaper: the guide does not give the defaults.
- Audacity 4.0.2: the UI stores settings under module `au3audio` (default off). The engine reads the same names under module `au3wrap` (library default on). I found no link between them. The effective default is unconfirmed.
- Hindenburg PRO: no latency page found. The setting can still exist.

## Sources

- S1: https://support.apple.com/guide/logicpro/devices-preferences-lgcpbb81aca5/mac
- S2: https://support.apple.com/guide/logicpro/use-io-utility-lgcef2d8c7d2/mac
- S3: https://support.apple.com/guide/garageband/change-audiomidi-settings-gbnd967819b9/mac and https://support.apple.com/guide/garageband/change-advanced-settings-gbnded6e79bc/mac (no latency text)
- S4: https://github.com/audacity/audacity/tree/Audacity-3.7.9: `libraries/lib-audio-io/AudioIO.cpp` (898, 2996-3000), `libraries/lib-audio-devices/AudioIOBase.cpp` (1085), `src/prefs/DevicePrefs.cpp` (333)
- S5: https://support.audacityteam.org/llms-full.txt (Latency Compensation page) and https://forum.audacityteam.org/t/latency-test/65001
- S6: https://github.com/audacity/audacity/tree/Audacity-4.0.2: `au3/libraries/au3-audio-io/AudioIO.cpp` (722, 1004), `au3/libraries/au3-audio-devices/AudioIOBase.cpp` (1090), `src/au3audio/internal/au3audiodrivercontroller.cpp` (240), `src/au3wrap/internal/au3commonsettings.cpp` (20), `BufferAndLatencySection.qml`. Master 9f09f496 has the same code.
- S7: https://resources.avid.com/SupportFiles/PT/Pro_Tools_Reference_Guide_2025.12.pdf, printed pages 69 and 1464
- S8: https://www.reaper.fm/userguide/ReaperUserGuide784c.pdf, section 3.37, page 76
- S9: https://web.archive.org/web/20250618214129/https://wiki.cockos.com/wiki/index.php/How_to_Compensate_for_Interface_Latency (archive copy; the live wiki redirects to the home page)
- S10: https://hindenburg.com/academy/guides/guides-hindenburg-pro/ , https://hindenburg.com/academy/shortcuts/shortcuts-hindenburg-2-pro/ , https://hindenburg.com/support/release-notes/ (no latency text)
