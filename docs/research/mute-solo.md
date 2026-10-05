# Mute and Solo on a track in other editors

Date: 2026-10-05

This file answers eight questions on the M and S buttons of a track. It does not repeat `docs/research/session-formats.md` (a Hindenburg `.nhsx` Track has a Muted attribute) or `docs/research/logic-garageband-update.md`.

Grades: **P** is a primary vendor page or manual. **S** is a search summary or a secondary page. **U** is a user post on a forum. "Unconfirmed" means that no source answers. A sentence that starts with "Inference:" is our reading. No probe, build, or on-screen check ran, because a bench and a push check run. The Apple help pages (support.apple.com) returned only the menu text to the fetch tool for most pages. Their quotes come from a mirror or a search summary.

## 1. Look and place of the buttons

- **Hindenburg.** The "M" and "S" buttons sit left of each track [HB] (S). Colors: unconfirmed. Hindenburg Pro help has a "Mute" and "Solo this track" entry in the Tracks menu [HG] (S, menu text only).
- **Logic.** Mute button "turns blue". Solo button "turns yellow" [LM] (S, mirror of the Apple page). Both buttons are in the track header and in the channel strip.
- **GarageBand.** "The Solo button turns yellow and the Mute buttons of all unsoloed tracks flash blue." [GS] (P). Mute, Solo, and Record Enable are in the track header [GS2] (S).
- **Audition.** "M" and "S" on each track [AUW] (S, university manual). The Editor and Mixer panels both have the buttons [AUS] (S).

## 2. Keys for the selected track

- **Hindenburg.** Shift-M mutes the track. Shift-S solos it. Shift-R arms it [HK] (S, summary of the shortcut page; the page itself is the owner).
- **Logic.** Key command "Toggle Track Mute" is M. Control-M is for regions, not for tracks [LS] (S). Solo: the control bar Solo button, or the Solo key command; Option-S locks region solo [LS] (S).
- **GarageBand for Mac.** No key in the sources (unconfirmed). GarageBand for iPad and iPhone: "Mute the selected track: M, Solo the selected track: S" [GI] (S). Inference: the Mac keys are likely the same; not checked.
- **Audition.** The default shortcut page refused the fetch (unconfirmed).

## 3. Solo behavior

- **Hindenburg.** The "S" button "allows you to listen to one track by itself" [HB] (S). Option-click "will now toggle mute and solo for all tracks. Included in 1.52.2110" [HU1] (U, a staff reply on UserVoice). A user asks for an exclusive solo that clears other solos [HU1] (U). Inference: Hindenburg has no exclusive solo. Several solos adding up: unconfirmed.
- **Logic.** "Option-click an unsoloed channel strip. This action solos the selected channel strip and unsolos any other channel strip." Option-click an active Solo button clears all solos [LM] (S). Solo-safe: Control-click an inactive Solo button; a red slash shows it [LM] (S). A drag across several buttons sets them all [LM] (S). Plain clicks add up: Inference, because the exclusive form needs Option.
- **GarageBand.** Several solos: drag over the Solo buttons, or Shift-click track names with the control bar Solo on [GS] (P). Solo safe: "Control-click the Solo button in a track header." [GS] (P). Option-click: not in the page.
- **Audition.** "To automatically remove other tracks from Solo mode, Ctrl-click (Windows) or Command-click (macOS)." Preference "Track Solo: Exclusive" makes it the default. Command-Shift-click on a button sets all tracks [AUH] (S, search summary of the Adobe page; the page refused the fetch with 403).
- **Solo over mute on one track.** No source states it (unconfirmed). Logic mutes all unsoloed tracks; GarageBand "Mute buttons of all unsoloed tracks flash blue" [GS] (P). Inference: a track that is muted and soloed is heard in the DAWs that flash the Mute of unsoloed tracks only; not checked.

## 4. Export, bounce, mixdown

This is the key question. No Hindenburg page states it.

- **Hindenburg.** A staff post says: "Currently Hindenburg can export either a single track (by soloing it) or a downmix of all channels." [HU2] (U, staff post on UserVoice). So a solo changes the export to the soloed track. Muted tracks in the export: unconfirmed. Inference: a mute also leaves the export, because the "M" button is part of the mix; no page proves it.
- **Logic.** "To include tracks in a bounce, make sure the tracks are routed to the main output and are not muted." [LB] (S, search summary of the Apple page). An active solo gives a silent or partial bounce [LB] (S, Apple Community post).
- **GarageBand.** Export bounces the mix. A solo left on means only that part exports [GE] (S). A muted track still sets the length of the export [GA] (U).
- **Audition.** "Anything not routed to the master output or muted won't be exported." [AUC] (S, summary of Adobe forum posts). Muted tracks with effects still cost export time [AUC] (S). The mixdown can also use "Selected Tracks" only [AUC] (S).
- Inference: the four apps use mute and solo in the export. A bounce is the same mix as the playback.

## 5. Saved in the file, and undo

- **Hindenburg.** The Muted attribute is in the `.nhsx` (session-formats.md). A solo attribute: unconfirmed.
- **Logic, GarageBand, Audition.** No source (unconfirmed). Logic keeps a solo-safe state in the project [LM] (S).
- **Undo.** No source for any app (unconfirmed).

## 6. During recording

- No source for any app (unconfirmed). Audition has separate "Arm For Record" and "Monitor Input" buttons next to Mute and Solo [AUH] (S). Inference: a mute is separate from arm; not checked for a recording.

## 7. Master meter and auto level

- No source (unconfirmed) for the master meter, or for Hindenburg auto level and muted tracks. Inference: the master meter shows the muted mix, because the export uses the muted mix (question 4); not checked.

## 8. A change during playback

- No source states a fade, a click, or a delay (unconfirmed). Logic says that you can mute and solo "during playback" nowhere in the pages that were read. Inference: the change is immediate; the click risk is not documented.

## For the plan

1. Look: Mute blue, Solo yellow in Logic and GarageBand [LM] [GS]. Letters "M" and "S" at the left of the track in Hindenburg and Audition.
2. Keys: Hindenburg Shift-M, Shift-S [HK]. Logic and GarageBand: M and S (Logic: M; GarageBand: iPad only).
3. Solo: several solos add up. An exclusive solo is a modifier-click (Logic Option, Audition Command). Hindenburg Option-click is "all tracks" [HU1].
4. Export: the mix follows mute and solo in all four apps (grade S and U only).
5. Open: solo saved, undo, recording, meter, auto level, fade on change.

## Sources

- [HB] Buzzsprout, Hindenburg Journalist review (2020): https://www.buzzsprout.com/blog/hindenburg-journalist-review-and-walkthrough
- [HG] Hindenburg Pro guides page: https://hindenburg.com/academy/guides/guides-hindenburg-pro/
- [HK] Hindenburg Pro shortcuts (the fetch returned a summary): https://hindenburg.com/academy/shortcuts/shortcuts-hindenburg-2-pro/
- [HU1] Hindenburg UserVoice, "Toggle solo / mute": https://hindenburg.uservoice.com/forums/224350-general/suggestions/40582099-toggle-solo-mute
- [HU2] Hindenburg UserVoice, "Export multiple tracks": https://hindenburg.uservoice.com/forums/224350-general/suggestions/38517292-export-multiple-tracks
- [LM] Logic Pro, "Mute and solo channel strips" (Apple page returned menu text only; text read on a mirror): https://logicpro.skydocu.com/en/mix/mixer-channel-strips/mute-and-solo-channel-strips/ and https://support.apple.com/guide/logicpro/mute-and-solo-channel-strips-lgcpbc21a09d/mac
- [LS] Search summary of https://support.apple.com/guide/logicpro/mute-tracks-lgcp08bafdee/mac and https://support.apple.com/guide/logicpro/mute-and-solo-regions-lgcp2217b80d/mac
- [LB] Search summary of https://support.apple.com/en-my/guide/logicpro/lgcp785a41c3/mac and https://discussions.apple.com/thread/256215869
- [GS] GarageBand for Mac, "Solo tracks": https://support.apple.com/en-sg/guide/garageband/gbnd1157ae2a/mac
- [GS2] GarageBand for Mac, "Intro to track headers" (search summary): https://support.apple.com/en-md/guide/garageband/gbnd6143101c/10.4.4/mac/11.0
- [GI] GarageBand for iPad, keyboard shortcuts (search summary): https://support.apple.com/guide/garageband-ipad/use-keyboard-shortcuts-chs88452c59a/ipados
- [GE] Search summary of export posts: https://violetrecording.com/how-to-export-from-garageband/
- [GA] Apple Community, "How to export non-muted tracks": https://discussions.apple.com/thread/8030658
- [AUH] Search summary of Adobe Help "Use basic multitrack controls" (403 on fetch): https://helpx.adobe.com/audition/using/basic-multitrack-controls.html
- [AUW] University of Wisconsin Audition manual: https://sts.doit.wisc.edu/manuals/audition/
- [AUS] Same Adobe page, search summary: https://helpx.adobe.com/au/audition/using/basic-multitrack-controls.html
- [AUC] Search summary of Adobe Community posts on multitrack mixdown: https://community.adobe.com/questions-544/export-multitrack-mixdown-produces-silent-files-165143
