# Leveler, duck, and manual gain: reference behavior in other editors

Date: 2026-11-08

Scope: how a leveler that writes gain points composes with a duck and with manual gain. [n] points to `## Sources`.

## Pro Tools

- Clip gain is applied pre-mixer: before the fader and before plug-in processing. Range is -144 dB to +36 dB. Settings stay with the clip. [1]
- The Clip Gain Line holds breakpoints. It is separate from track volume automation. [1]
- Inserts on audio tracks are pre-fader. [1] Inference: volume automation moves the fader, so it acts after the inserts.
- Trim automation (Ultimate and Studio only) has its own playlist. A trim move writes a relative delta on top of the existing volume automation. [1]
- "Convert" cuts clip gain and pastes it as volume automation, or the reverse. "Coalesce" merges the two. Clip gain above +12 dB is lost on conversion to volume automation. [1]
- A leveler plug-in sits in an insert. Waves Vocal Rider says to insert it as the last plug-in on the track. [3] Inference: its input is the audio after clip gain, because clip gain is pre-insert.
- Vocal Rider does not write clip gain or track volume. Its "Rider Fader" is a plug-in parameter (-12 dB to +12 dB). In Write mode it sends every move to the host automation lane for that parameter. The host treats the moves as hand-written automation. [3]
- Write and Latch erase earlier automation on that lane. A second Write pass replaces the first. [4]
- AudioSuite modes that render clip gain apply the clip gain first, then the effect. [1]
- Pro Tools has no built-in duck in the sources read. Vocal Rider ducks by a sidechain. [4]

## Logic Pro

- Region Gain is one static value per audio region, -30 dB to +30 dB. It is set in the Region inspector or with the Gain tool. [6][9]
- A Gain tool edit on a Marquee part of a region creates a new region with the gain applied. [6]
- Normalize Region Gain is nondestructive. It uses peak or loudness (LUFS) and sets a region gain. [7]
- Automation is track-based or region-based. Each track has volume and pan curves. You can add plug-in curves. [5][8]
- Trim mode scales existing volume automation. Relative mode adds a second curve that offsets the main curve. Both curves stay visible. [8]
- The pages read do not give the order of region gain, plug-ins, and the volume curve. They show no leveler or duck feature.

## iZotope RX

- Leveler "rides the gain". It is a compressor with makeup gain. It uses K-weighted RMS and a built-in limiter. [11][12]
- It writes the result as a Clip Gain envelope. The user can view and edit it. [11][12]
- If another module runs after Leveler, the clip gain values are written into the audio and the nodes return to zero. The Leveler step stays in Undo History. [11][12][14]
- The guide does not say: whether Leveler measures audio after the existing clip gain, whether it replaces or adds to existing points, or what a second run does. Inference: a second run first bakes the first envelope, then measures the baked audio.

## Hindenburg (Journalist PRO 1.21, PRO 2)

- Version 1.21 guide: Hindenburg has no rubber bands. Volume editing is done to the region itself. You drag the top (gain) line. [15]
- Auto Level sets the region level on import: -9 QPPM peak, -21 LUFS narration, -23 LUFS music. Tools / Auto Level re-analyzes selected regions. [15]
- The top handle snaps back to the green auto level readout. A tooltip shows two numbers: the current level and the gain change made by the user. [15] This is a documented baseline plus user delta.
- A Duck on a selection creates fade handles. The user drags the top handle. [15] In 1.21, Duck and manual gain use the same region gain mechanism.
- PRO 2 gain range is +40 dB to -40 dB. This gain "does not interfere with the auto levelling". [18]
- PRO 2 Magic Levels reduce mic bleed, apply loudness-based gain riding, and duck music under speech. The text says "without manual automation passes". [16][17]
- PRO 2 lists Duck, Copy & Duck, Magic Levels, Auto Level, and Clipboard. The Clipboard organizes clips and does not change gain. [17][19]
- No page read states what Magic Levels writes (region gain, fade handles, or points). No page states how Magic Levels and Duck combine. Inference: both use the 1.21 region gain and handles model.

## Final Cut Pro

- Range Selection plus a volume drag creates volume keyframes along the range. Apple presents this as the way to duck. [20]
- Modify > Adjust Volume > Absolute sets one level and deletes keyframes. Relative shifts the level and keeps fades and keyframes. [20]
- Loudness (Audio Enhancements) has Amount (compression) and Uniformity (dynamic range) sliders. It works per audio component. It is a setting, not a keyframe set. [21]
- The pages do not say how a range edit merges with existing keyframes inside the range. They show no automatic duck.

## Adobe Audition

- Clip envelopes (volume, pan, effects) and track envelopes (automation lanes) are separate. Both are nondestructive. Write mode overwrites keyframes on a track lane. [23]
- Essential Sound Ducking is for Music and Ambience clips. Controls: Duck Against, Sensitivity, Reduce By, Fades, Monitor Clip Changes, Reanalyze Clips. [24]
- It generates clip volume keyframes on the music clip, shown as a dotted envelope. With Monitor Clip Changes on, it updates after edits. With it off, the dotted line becomes normal keyframes. [28]
- The sources do not say what a second Audition run does to hand-edited keyframes.
- Premiere Pro ducking adds an Amplify effect. Duck keyframes go to its gain parameter, apart from other sound design. A second Generate Keyframes overwrites all manual changes to them. [29]
- Unify Loudness > Auto Match shows the matched LUFS. Match Clip Volume is nondestructive in the Multitrack Editor. The pages do not say where the gain is stored. [24][25]
- Speech Volume Leveler is a compression effect. [26] In the Multitrack Editor effects are nondestructive. In the Waveform Editor, Apply changes the audio data. [27]

## DaVinci Resolve (Fairlight)

- Each clip has a clip gain line. It takes keyframes. [30]
- Dialogue Leveler and Ducker are Track FX. The guide also separates clip-level from track-level use. They write no points. The guide says the Ducker works "without the need for keyframes or automation". [30]

## Descript

- "Lower audio of other layers" is a layer effect. It follows clip presence on the layer, not the audio. Volume keyframes are separate. The pages do not say how the two combine. [31][32]

## Auphonic

- The Adaptive Leveler works inside one file. Loudness normalization is a separate constant gain. The page does not say if the result is rendered. [33]

## REAPER

- Volume (Pre FX) envelope acts before the track FX chain. Volume envelope acts on the track output. Trim Volume envelope comes after the Volume envelope. [34]
- No built-in leveler or duck found. The guide does not state the combine math. Inference: stages in series add in dB.

## Summary

| App | Leveler writes | Duck writes | Manual gain | Leveler measures | Second leveler run | Duck after leveler |
|---|---|---|---|---|---|---|
| Pro Tools | Plug-in parameter lane (Vocal Rider) | No built-in duck | Clip gain line, volume, trim | Inference: audio after clip gain | Write replaces lane | Not documented |
| Logic Pro | No leveler found | None found | Region gain, volume curves, relative curve | n/a | n/a | n/a |
| RX | Clip gain envelope | n/a | Clip gain line | Not documented | Not documented | n/a |
| Hindenburg | Region level (Auto Level, 1.21); Magic Levels not documented | Fade handles on region (1.21) | Region top handle | Not documented | Re-analysis resets level | Not documented |
| Final Cut Pro | Loudness setting | Volume keyframes (manual range) | Volume line, keyframes | Not documented | n/a | n/a |
| Audition | Effect (Leveler); Auto Match | Clip volume keyframes | Clip envelope, track envelope | Not documented | Not documented | Not documented |
| Premiere Pro | n/a | Amplify gain keyframes | Clip Volume, keyframes | n/a | n/a | Own effect layer |
| Resolve | Track FX (clip use also offered) | Track FX | Clip gain line | Not documented | n/a | Both are FX |
| Descript | n/a | Layer effect | Volume keyframes | n/a | n/a | Separate |

Patterns that keep layers apart: a plug-in parameter lane (Pro Tools), a second curve (Logic Relative), a separate effect (Premiere Amplify, Resolve Track FX, Descript layer effect), and a baseline plus user delta (Hindenburg 1.21). Only RX writes a leveler result to the clip gain line, and RX bakes it on the next module.

## Open questions

Each item is an Inference or an undocumented point.

1. Pro Tools: volume automation acts after inserts. Inference.
2. Pro Tools: Vocal Rider input is audio after clip gain. Inference.
3. RX: second Leveler run bakes the first envelope. Inference. Needs an RX probe. Existing points in the selection: undocumented. RX 11 pages were not readable.
4. Hindenburg PRO 2: what Magic Levels writes, and Magic Levels with Duck on one clip. Inference in the Hindenburg section.
5. Logic Pro: order of region gain, inserts, and volume curve. Undocumented.
6. Final Cut Pro: range edit versus existing keyframes. Undocumented.
7. Audition: second Ducking run, Auto Match storage, clip envelope versus clip effect order. Undocumented.
8. Descript: ducking with volume keyframes. Undocumented.
9. REAPER: envelope combine math. Inference: series stages add in dB.
10. What each leveler measures (Hindenburg Auto Level, Audition, Resolve) is undocumented.
11. Adobe helpx blocked direct fetch. Audition and Premiere text came from web.archive.org snapshots.

## Sources

1. Avid, Pro Tools Reference Guide 2024.10 (Clip Gain, Trim Mode, Audio Tracks and Signal Flow): https://resources.avid.com/SupportFiles/PT/Pro_Tools_Reference_Guide_2024.10.pdf
2. Avid, Clip effects (pre-fader): https://www.avid.com/pro-tools/user-guide/clip-effects
3. Waves, Vocal Rider User Guide: https://www.waves.com/1lib/pdf/plugins/vocal-rider.pdf
4. Waves, Vocal Rider In Depth: https://www.waves.com/vocal-rider-in-depth
5. Apple, Track vs. region automation: https://support.apple.com/guide/logicpro/lgcp967649d0/mac
6. Apple, Change the gain of audio regions: https://support.apple.com/en-us/102037
7. Apple, Normalize audio regions: https://support.apple.com/guide/logicpro/lgcp663fdd13/mac
8. Apple, Choose automation modes: https://support.apple.com/guide/logicpro/lgcpb1a6ab26/mac
9. Apple, Audio region parameters: https://support.apple.com/guide/logicpro/audio-region-parameters-lgcpf7c0af60/mac
10. Apple, Gain plug-in: https://support.apple.com/guide/logicpro/lgcef2d8c650/mac
11. iZotope, RX 10 Leveler: https://docs.izotope.com/rx10/en/leveler/index.html
12. iZotope, RX 9 Leveler: https://s3.amazonaws.com/izotopedownloads/docs/rx9/en/leveler/index.html
13. iZotope, RX 10 Interactive Tools: https://docs.izotope.com/rx10/en/interactive-tools/index.html
14. iZotope, RX 10 Undo History: https://docs.izotope.com/rx10/en/undo-history/index.html
15. Hindenburg, Journalist PRO user guide 1.21 (copy hosted by a third party): https://www.willyurman.com/teaching/handouts/Hindenburg_Journalist.pdf
16. Hindenburg, PRO features: https://hindenburg.com/products/radio-podcast/features/
17. Hindenburg, PRO 2 shortcuts: https://hindenburg.com/academy/shortcuts/shortcuts-hindenburg-2-pro/
18. Hindenburg, KB gain more than 15 dB: https://hindenburg.uservoice.com/knowledgebase/articles/2004124-how-to-gain-more-than-15db
19. Hindenburg, Story editing (Clipboard): https://hindenburg.com/hindenburg-pro-features/story-editing/
20. Apple, FCP Adjust volume: https://support.apple.com/guide/final-cut-pro/adjust-volume-verc1fabb77/mac
21. Apple, FCP Enhance audio: https://support.apple.com/guide/final-cut-pro/enhance-audio-verc1fab873/mac
22. Apple, FCP Keyframe audio effects: https://support.apple.com/guide/final-cut-pro/keyframe-audio-effects-ver717f5914/mac
23. Adobe, Audition envelopes (archive): https://web.archive.org/web/20250124123852/https://helpx.adobe.com/audition/using/automating-mixes-envelopes1.html
24. Adobe, Audition Essential Sound panel (archive): https://web.archive.org/web/20241231012029/https://helpx.adobe.com/audition/using/essential-sound-panel.html
25. Adobe, Audition clip volume (archive): https://web.archive.org/web/20250124123852/https://helpx.adobe.com/audition/using/clip-volume-matching-fading-mixing.html
26. Adobe, Audition amplitude and compression effects (archive): https://web.archive.org/web/20241231012029/https://helpx.adobe.com/audition/using/amplitude-compression-effects.html
27. Adobe, Audition effects in Multitrack and Waveform editors (archive): https://web.archive.org/web/20241231012029/https://helpx.adobe.com/audition/using/applying-effects-multitrack-editor.html and https://web.archive.org/web/20241231012029/https://helpx.adobe.com/audition/using/applying-effects-waveform-editor.html
28. Adobe blog, Audition auto-ducking: https://blog.adobe.com/en/publish/2017/11/02/audition-deep-dive-auto-ducking-music
29. Adobe, Premiere Pro auto ducking (archive): https://web.archive.org/web/2024/https://helpx.adobe.com/premiere-pro/using/auto-ducking.html
30. Blackmagic, Fairlight Audio Guide to DaVinci Resolve 20: https://documents.blackmagicdesign.com/UserManuals/DaVinciResolveFairlightAudioPost.pdf
31. Descript, Lower audio of other layers: https://help.descript.com/hc/en-us/articles/4404610008461-Ducking
32. Descript, Volume keyframes: https://help.descript.com/effects-animations-transitions/volume-automation-and-keyframes
33. Auphonic, Algorithms: https://auphonic.com/help/algorithms/singletrack.html
34. Cockos, REAPER User Guide v7.85: https://dlx.reaper.fm/userguide/html/
