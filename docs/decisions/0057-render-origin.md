# 0057. A rendered file keeps its origin: the input file, the treatment, and the added gain

- Status: accepted
- Date: 2026-10-14
- Accepted: 2026-10-27, after plan gates 1 to 3 of run `2026-10-14-render-link`.
- Amends: 0055 (the words of a transcript anchor to the root file of a chain), 0061 (a rendered file of a take file has the take origin of its root), 0002 (`DirigibleCore` owns the stored render settings), 0009 (the session stores the effect as rendered, in the origin), 0056 (`addDerivedFile` copies no word into a file with an origin), 0003 (a `<file>` can hold one `<origin>`), 0024 (`session.xml` version 12 with an origin), 0042 (a copy into another package has no origin), 0047 (the origin chain of a held file holds its sources), 0054 (a render writes an origin; a second render of one kind replaces, it does not stack; `repoint` writes the second-pass gain).
- Amended: 2026-10-28, run `2026-10-13-render-denoise`, landing 2 (see 0054). D9: an origin with hum holds `<hum hz>` (50 or 60) before `<noise>`, and `session.xml` is version 13 when an origin holds hum. The reader refuses `<hum>` in a file of version 12 or lower, and `hz` other than 50 and 60.
- Amended: 2026-10-29, run `2026-10-27-repair-set` (see 0064 D6). D4: the render places each requested kind on its own. A kind with a level gets its new value in that level. A kind with no level joins the lowest level whose kept kinds (not removed, not moved to another level) hold a later kind of the chain. With no such level, it goes in one new level on top, which each such kind of the request shares. So one request can change two levels, with one undo entry. The renders start at the lowest level that holds a set or removed kind, or that a kind joins. A clip is unchanged when each rebuilt level equals its stored level, for each kind: declip, rumble, and deess read only file samples, as noise and hum do.

## Context

User decision A8 (2026-10-14): a rendered clip keeps a link to its original, so the user can change the effect amount later with no Undo. The user reason: non-destructive editing is the intended pattern for everything in Dirigible. The link applies to each render effect of 0054: Reduce Noise, Level Over Time, and Match Voice.

0054 renders a run of clips into a new WAV and points the clips at it. It stores nothing about the render, so a second render processes processed audio, and only Undo goes back. Two effects measure their input before the render: the ride curve and the match target spectrum. Match Voice also measures a reference clip, which can change or go before a later change. A render adds clip gain: the peak scale (one gain for each run) and the match loudness correction.

Reference apps ([research](../research/render-link.md)): Final Cut Pro (Voice Isolation, Noise Removal, Loudness), Audition clip effects, and Hindenburg keep the effect live, with an amount that the user changes at any time. The Audition Waveform editor and the Logic Audio File Editor change the file, with Undo only. REAPER "Apply FX to items as new take" keeps the original take beside the rendered take, and the user switches back. Logic Bounce in Place makes a new file and keeps, mutes, or deletes the source region. No editor stores an offline render with a link to its settings; this record gives the REAPER result (the original stays, the user goes back) with the amount change of a live effect.

## Decision

**D1. The origin is on the rendered file.** `AudioFile.origin: RenderOrigin?` holds the direct input file (`source`), the source frame of file frame 0 (`offset`), the treatment as rendered, and the gain that the render added to each clip of the run (`addedGain`). File frame i is source frame `offset + i`. A recorded, imported, pasted, or split file has no origin. A split, a trim, a move, a ripple, and a crossfade change clip fields only, so each keeps the link.

**D2. A chain of direct inputs.** Each render adds one level: its source can be another rendered file. A file with no origin is the root.

**D3. The origin stores what the input cannot give again.** The treatment and the added gain are stored. A match stores its reference as a spectrum (the speech and noise power of 25 one-third-octave bands, and the gated seconds). The stored `Effect` type cannot hold a clip ID; only the request type (`EffectRequest`) names a reference clip, and the measure phase is the one place that turns a request into the stored form. The ride curve and the target spectrum are measured again from the input at each render.

**D4. Change the amount.** A render on clips whose chain has a level with a requested kind lowers the clips below the lowest such level, rebuilds that level with the stored treatment where each requested effect replaces the effect of its kind, takes the requested kinds out of each level above (a level with no effect left goes), and renders each level above again with its stored treatment. The merge, the removal, and the compare are operations of the request type, so a request is never compared with a stored effect of another shape. It is one undo step. Two levels of one kind never come from a render: a second render replaces. Clips of one level whose rebuilt requests differ render in one call for each request, because one run of one file takes one treatment. When each requested effect is noise or hum and equals the stored one, and the stored span covers the new run span with its handles, the clip is unchanged. When each clip is unchanged, the render makes no file, no save, and no undo entry, and it reports "Nothing to change." The plan is made in the blocking run, so the busy refusals of a render apply and the Player stops. In a request where other clips change, an unchanged clip keeps its file, offset, gain, and envelope. A ride or a match reads the clip gain, so its level always renders again. One space check before the first level covers all levels, and the progress of the levels only rises.

**D5. One added gain for each run.** `addedGain` is the dB of the second-pass scale of 0054 (0 dB with no second pass). `repoint` adds it to each clip of the run and stores it in the origin, so one call owns the gain and the record. Lower and Restore Original subtract it from each clip gain and move the gain envelope back with the rule of 0060. The user gain stays. The render and the restore clamp to `Gain.range`, so a restore is exact unless the gain before the render was within `addedGain` of the top of the range. The match loudness correction is one gain for each run, so a split clip restores exactly.

**D6. Restore Original.** Tools > Restore Original Audio (Shift-Command-O, after Reduce Noise, also in the lane menu), `dirigible clip restore`, and `clip_restore` (a batch step of 0063) move the clips to the root file at the frame that they played, with the added gains removed. They write no file. A clip with no origin stays.

**D7. Holders.** Remove Unused Files keeps each file that the origin chain of a held file names, and its pool entry (0047 holders: the session, each readable backup, each undo and redo entry, and the clipboard). The clipboard holder adds the chain of each record through the live pool. `Session.removeFile` refuses a source that an origin names (`.fileIsSource`). The prune and the history remove a set of files in one step: one guard pass against the pool minus the set, then the removal body of one file for each, which also drops its words. So the order of a set never matters.

**D8. Paste.** A paste in the same package keeps the file record, so the link stays. A paste into another package copies only the clip files, under new records with no origin.

**D9. Format.** `session.xml` version 12 when a file has an origin; else the version of today (0024 P6). The `<origin source offset gain>` element holds one element for each effect, in chain order (`<noise decibels>` in this record). Each later kind (hum, ride, match) adds its element and takes the next version in the run that adds it (0024 P7), because each land ships a build to the tester, and a build must call a file with an unknown element newer, not damaged. The writer writes the files by ID, so the reader adds all files first and then sets the origins in one check pass. The reader refuses an origin in a file of version 11 or lower, an unknown source, a source that is the file, another layout, a range past the source, a cycle, an origin with no effect, a repeated kind, and a value outside its type.

**D10. Types.** `Effect`, `Treatment`, and the setting values live in `DirigibleCore`, because the reader parses them; they move from `DirigibleAudio/Render/`, where 0054 put them. The DSP mappings (the wet mix, the stem suffix, the unit check, the role rule `Treatment.accepts`) stay in `DirigibleAudio`.

**D11. Words.** The words of a transcript anchor to the root file of a chain, in root frames (0055 amended). A clip on a rendered file reads them through the sum of the origin offsets, and an import over a rendered clip (by timeline or by take time) writes them to the root. A render, a change, and a restore move no word, and a render copies no word into its file. Each copy of words into another file goes through one helper: each root anchor whose midpoint is in the span goes to the part of its range inside the span, minus the span start, with the same word ID. A split to mono (no origin) and a copy for a paste into another package use it, so no path stores a word outside its file. A transcript with a word keyed by a file that has an origin does not load (the not-loaded rule of 0055).

**D12. Take time.** A rendered file whose root is a take file has the take origin of the root plus the sum of the origin offsets (0061 amended). So a rendered clip keeps its take time, and a render or a restore does not change the sync state of a take. A split file and an imported file still have none.

## Consequences

- A second Reduce Noise on a reduced clip renders from the source of its noise level, at the new amount.
- An intermediate file of a chain stays on the disk while a held file names it.
- A pasted copy in another package cannot change its amount. The user changes the amount in the source session first.
- A split to mono of a rendered stereo file keeps the rendered audio and loses the link.
- The previous build refuses a session with an origin as made by a newer version (0024 P3).
- A re-render of a ride reads the current clip spans and gains.
- A clip rendered before this record is on a root with no link: it goes back only with Undo. A new Reduce Noise on it adds a second pass on top of the first, and Undo is the way back. The guide says so.
- Each later effect kind raises the `session.xml` version once.
- A restore of a clip whose gain was within the added gain of 96 dB gives a lower gain. Only a CLI or MCP gain reaches it: the inspector clamps at 20 dB.

## Alternatives considered

- **One link to the root with a merged treatment.** One level and no intermediate file. But a ride or a match after a noise level measures the noise output, so a change still renders each lower level, and a match change renders the noise level again at about 1/8 of real time.
- **The link on the clip.** A split copies it, and a trim and a crossfade must rewrite its range.
- **A live clip effect (0009 as written).** 56 to 76 ms of latency and the render cost at each play and export (0054).
- **Store the ride curve and the target spectrum.** About 576 KB for 2 h in each save, and wrong after an edit of the input.
- **Copy the source chain at a paste into another package.** The source can be a 1 h take for a 10 s clip.
- **One version for all four kinds, with this record after the last effect run.** One raise, but each clip rendered before it lands has no link.
- **Later kinds share version 12 until a release.** Each land ships a build to the tester, so a build with no element for a kind would call a newer session damaged.
