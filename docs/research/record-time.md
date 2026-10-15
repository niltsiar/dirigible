# Record time left: reference behavior

Date: 2026-10-15

Question: how do the reference apps show the record time or the free disk space left, when do they show it, and at what level do they warn?

## Per app

| App | Readout | When it shows | Warning level | Sources |
|---|---|---|---|---|
| Hindenburg PRO | None documented. The System Monitor toolbar shows CPU and disk usage, not free space. The Call Recorder shows "Running Time", the length of the recording. | - | None documented | [H-SC], [HM], [HR] |
| Logic Pro 12 | None documented | - | None documented. "Before recording audio" tells the user to check "disk space". | [L-BR], [L-RS], [L9] |
| GarageBand | None documented | - | None documented. "Before recording audio" has no disk step. | [G-BR] |
| Final Cut Pro | None documented. The Record Voiceover page names the audio meters only. | - | None documented | [F-VO] |
| Cubase and Nuendo 12 | Max. Record Time display; also the status line above the track list | When the user opens it, or when the status line shows | None documented | [C-RT] |
| Audacity | "Disk space remaining" in the status bar | After the first recording of the project window, when the mouse is still for some seconds | 100 MB or less, at startup and at File > New; "Out of disk space" in the status bar | [A-SB], [A-RL], [A-W] |
| Adobe Audition | Free Space (Time) item of the status bar | Hidden by default; the user turns it on | None found | [AU-WS] (search excerpt only) |
| REAPER 7.81 | "Show free disk space" at the right end of the menu bar | When the user turns on the option | A check of free disk space at the record start; the amount is not in the guide | [R-UG] |
| WaveLab LE 11 | Disk capacity indicator in the Recording dialog | In the Recording dialog | Red under 30 s | [W-DC] |
| mimoLive | Estimated record time of the file output | During a recording, about every 5 s | Yellow at about 30 min, red at 10 min | [M-FR] |
| Audio Hijack | None documented | - | None. A recording splits at 2 GB or 24 hours. | [AH-RB] |

## Sources

- [H-SC] Hindenburg Pro shortcuts: https://hindenburg.com/academy/shortcuts/shortcuts-hindenburg-2-pro/
- [HM] Hindenburg Journalist 1.21 user guide for macOS, hosted by willyurman.com: https://www.willyurman.com/teaching/handouts/Hindenburg_Journalist.pdf
- [HR] Hindenburg PRO release notes: https://hindenburg.com/support/release-notes/hindenburg-series/
- [L-BR] Logic Pro User Guide, Before recording audio: https://support.apple.com/guide/logicpro/before-recording-audio-lgcpb19de615/mac
- [L-RS] Logic Pro User Guide, Recording settings: https://support.apple.com/guide/logicpro/recording-settings-lgcp411dd5c8/mac
- [L9] Logic Pro 9.1.6 User Manual, Choosing the Recording File Type: https://help.apple.com/logicpro/mac/9.1.6/en/logicpro/usermanual/chapter_14_section_9.html
- [G-BR] GarageBand User Guide, Before recording audio: https://support.apple.com/guide/garageband/before-recording-audio-gbnd4c2cc43e/mac
- [F-VO] Final Cut Pro User Guide, Record voiceovers: https://support.apple.com/guide/final-cut-pro/verc1faa9c5/mac
- [C-RT] Steinberg Nuendo 12 Operation Manual, Remaining Record Time: https://archive.steinberg.help/nuendo/v12/en/cubase_nuendo/topics/recording/recording_remaining_record_time_c.html
- [A-SB] Audacity Manual, Status Bar: https://manual.audacityteam.org/man/status_bar.html
- [A-RL] Audacity Manual, Recording length: https://manual.audacityteam.org/man/recording_length.html
- [A-W] Audacity Manual, Warnings Preferences: https://manual.audacityteam.org/man/warnings_preferences.html
- [AU-WS] Adobe Audition help, Customizing the Audition workspace (search excerpt; a direct read gave HTTP 403): https://helpx.adobe.com/audition/using/customizing-workspaces.html
- [R-UG] Up and Running: A REAPER User Guide v 7.81, September 2026, pages 76 and 234: https://www.reaper.fm/userguide/ReaperUserGuide781c.pdf
- [W-DC] Steinberg WaveLab LE 11, Disk Capacity Indicator: https://archive.steinberg.help/wavelab_le/v11/en/wavelab/topics/recording/recording_disk_capacity_r.html
- [M-FR] mimoLive user manual, File Recording Performance Monitor: https://mimolive.com/user-manual/diagnostics/performance-monitoring/file-recording-performance-monitor/
- [AH-RB] Audio Hijack manual, Recorder block: https://rogueamoeba.com/support/manuals/audiohijack/?page=recorderblock
