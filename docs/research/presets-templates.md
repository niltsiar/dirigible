# Export presets and session templates in reference apps

Date: 2026-10-28

This file collects the reference behavior for F57 (export presets: several targets in one step) and F63 (session templates). The run `2026-10-28-presets-templates` reads it. The researcher agent could not start (subagent limit), so the run lead did the research with web pages and with read-only checks of the apps on the run Mac. A claim that no primary source confirms has the mark "(unconfirmed)".

## Findings

### Hindenburg

1. Hindenburg Journalist 1.21 has export options for each file format (WAV, MP3, AAC, Apple Lossless, AIFF). In Export > Options, the user makes named formats: "Make your own MP3 export formats and save them." Each named format has an encoding name, the channels, the bit rate (lossy formats), and the sample rate ("No conversion - follows session", 32000, 44100, 48000 Hz). The buttons are Add New, Delete, Reset to default, Save Configuration, and Set as default [HM p.77 and later].
2. Hindenburg 1-Click Publish uploads one session to several destinations in one action: "Once you have set up your upload accounts you can upload to multiple platforms with a single click." The user check-marks one or more accounts, then clicks Publish [HM p.73].
3. One publish account (for example File Upload / FTP) holds a name, a file format (MP3, MP2, AAC, Apple Lossless, AIFF), a file encoding (high, medium, or low quality), a server, a user name, and a password [HM p.70].
4. Hindenburg PRO: "Hindenburg PRO lets you easily export to any LUFS standard or even multiple standards at once." "We even provide export to multiple platforms at once!" [HS]. The PRO guide lists the publish target settings: "Audio export options: File Format, File Encoding, Loudness Normalization, Username, and Password" [HG].
5. Hindenburg recommends two exports of one episode: "Always save a high-quality WAV file as your master and export MP3s for distribution." Podcast: "MP3, 128 kbps, 44.1 kHz, mono, targeting -16 LUFS." Broadcast radio: "WAV, 16-bit, 48 kHz, stereo, targeting -23 LUFS (EU) or -24 LUFS (US)" [HD].
6. Hindenburg has no documented "Save as Template" for sessions. It has one default session: "File / Properties / Defaults. Save default session > saves current settings as default. Reset default session > When a new session is created it will have the default properties" [HM]. A new session opens "with an empty session with the following tracks": Speak, Interview, Ambience, Music [HM p.13]. The PRO guide has the entry "Properties - Default: Save default session. Revert to factory settings" [HG].
7. Hindenburg stores the named export formats and the publish accounts in the app, not in the session (inference from [HM]: the options are under Export > Options and File > Publish, not under session properties). A file that a user can copy to another Mac is not documented (unconfirmed).
8. Whether the Hindenburg default session holds clips, the clipboard, or the favorites is not documented (unconfirmed).

### Logic Pro and GarageBand

9. Logic Pro: "A project can be bounced to several different file formats simultaneously." In the Bounce dialog, the user can "select one or more destination formats in the Destination area" (PCM, MP3, M4A, burn) [LB].
10. Logic Pro names the files of one bounce by one rule: "When you bounce to multiple destination files, all the resulting files are saved in the chosen folder. All files have the same filename, but with the appropriate file extensions" [LB]. So one bounce cannot write two MP3 files.
11. Logic Pro: "choose File > Save As Template ... then enter a name." "In the Project Chooser, click My Templates to view and access templates you have created." The Save As Template dialog has a Create Folder button for template folders. A Finder comment on the template file gives its description [LS].
12. A Logic template is a project file (`.logicx`, UTI `com.apple.logicx.project`) [local: Logic Pro 12.4 `Info.plist`]. The user folder is `~/Music/Audio Music Apps/Project Templates/` [LU, a user forum; the folder exists on the run Mac, empty]. So a template is a normal project document that the user can copy (inference).
13. GarageBand 10.4.14 has six built-in project templates as `.band` packages in the app bundle, and no podcast template [GBL in `docs/research/logic-garageband-update.md`]. File > New shows the Project Chooser [docs/research/startup.md].

### Final Cut Pro

14. Final Cut Pro share destinations are in the Destinations pane of Settings. "As you customize the destination, your changes are saved automatically." A user can duplicate a destination and revert to the default set [FD].
15. A Final Cut Pro bundle groups destinations. Sharing with a bundle outputs one file for each destination in the bundle. Control-click > New Bundle from Selection makes one [FD].
16. Final Cut Pro asks the user to confirm the settings only of the first destination of a bundle, and uses the defaults for the others [LJ, secondary source].
17. A share destination can be a file. Final Cut Pro 12.3 declares the document type "Final Cut Share Destination", extension `fcpxdest`, UTI `com.apple.FinalCutPro.dest`, which conforms to `public.data` (a flat file, not a package) [local: Final Cut Pro 12.3 `Info.plist`]. A user drags a destination to the Finder to make the file [FI, secondary source].

### Not researched

18. Descript and Adobe Audition were not checked in this run. A plan claim about them needs a source first.

## Summary table

| App | A preset holds | Several targets in one step | Preset storage | A template holds | Template storage |
|---|---|---|---|---|---|
| Hindenburg Journalist 1.21 and PRO | Format, encoding, channels, rate; PRO adds loudness; a publish account adds a destination | Yes: check-mark several publish accounts; PRO "multiple standards at once" | In the app (inference) | One default session: tracks and settings | In the app, one default |
| Logic Pro | Bounce settings (not a named preset) | Yes: several formats in one bounce, one name with each extension | None | A whole project | `.logicx` file in `~/Music/Audio Music Apps/Project Templates/` |
| GarageBand | None | No | None | Built-in projects only | `.band` in the app bundle |
| Final Cut Pro | A share destination | Yes: a bundle writes one file for each destination | App settings; also an `.fcpxdest` file | Not checked | Not checked |

## Sources

- [HM] Hindenburg Journalist 1.21 user guide (Hindenburg Systems), hosted by willyurman.com: https://www.willyurman.com/teaching/handouts/Hindenburg_Journalist.pdf (text read from the PDF streams; page numbers from the page footers)
- [HS] Hindenburg PRO, Sharing: https://hindenburg.com/hindenburg-pro-features/sharing/
- [HG] Hindenburg Academy, Hindenburg PRO guide: https://hindenburg.com/academy/guides/guides-hindenburg-pro/
- [HD] Hindenburg, December 23 calendar post: https://hindenburg.com/2025-dec-calendar-content-1/december-23/
- [LB] Logic Pro 10.1 help, Bounce a project to an audio file: https://help.apple.com/logicpro/mac/10.1/en.lproj/lgcp785a41c3.html
- [LS] Logic Pro User Guide, Save projects: https://support.apple.com/guide/logicpro/save-projects-lgcpce128e82/mac
- [LU] Logic Users Group, "My Templates - where are you?": https://logic-users-group.com/threads/my-templates-where-are-you.9496/
- [FD] Final Cut Pro User Guide, Create share destinations: https://support.apple.com/guide/final-cut-pro/ver9fd008a21/mac
- [LJ] Larry Jordan, What is a Final Cut Pro Share Bundle?: https://larryjordan.com/articles/what-is-a-final-cut-pro-share-bundle
- [FI] FileInfo, .FCPXDEST file extension: https://fileinfo.com/extension/fcpxdest
- Local, read-only: `/Applications/Final Cut Pro.app/Contents/Info.plist` (12.3), `/Applications/Logic Pro.app/Contents/Info.plist` (12.4), `ls ~/Music/Audio Music Apps/` on the run Mac (2026-10-28).
