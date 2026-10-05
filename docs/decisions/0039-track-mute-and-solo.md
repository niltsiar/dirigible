# 0039. Track mute and solo: session flags in version 5, one audible rule, a Player crossfade

- Status: accepted
- Date: 2026-10-05
- Accepted: 2026-10-05, after plan gates 1 and 2 of run `2026-10-05-mute-solo`.
- Amends: 0003 (version 5 adds mute and solo), 0016 (an update during play crossfades a mute or solo change), 0019 (the track filter of `MixReader`), 0024 (the `session.xml` version table).

## Context

The tester asks for M and S buttons in each track header, as in Hindenburg PRO (feedback B2.12 and B2.13). Mute and solo change the mix, so they touch the one render path (`MixReader`) of the Player, the export, and `dirigible render` (0016, 0019). The flags can live in the session (saved, on the undo stack, in the CLI) or in the window, as the Arm set does.

Logic Pro, GarageBand, and Audition leave a muted track out of a bounce, and a Hindenburg solo exports only the soloed track. Hindenburg saves `Muted` per track. `dirigible export` and `render` read only `session.xml`. So a window state makes the app export and the CLI export of one package differ, on state that a reopen loses.

## Decision

- **Fields.** Each track has `isMuted` and `isSoloed`. `Session.setMuted(_:tracks:)` and `setSoloed(_:tracks:)` set a list of tracks; an unknown track throws and changes nothing.
- **Rule.** A track is audible when it is not muted, and no track is soloed or it is soloed. Mute wins over solo. Solos add. `Session.isAudible(_:)` is the one owner of the rule. `Session.heardTracks(in:)` gives the audible tracks of a track set (nil: all), in session order. `MixReader`, the export media check, and the export notes read it.
- **Mix.** The Player, the loudness meter, the export, the export loudness pass, and `dirigible render` follow the flags. Export Selection renders the selected tracks that are audible. When no track is heard, the file is silent. Auto Level ignores the flags (0031). The media check of an export skips the files of unheard tracks; the check with no source (play, open) stays whole-session.
- **Format.** `session.xml` is version 5 when a track is muted or soloed. The `<track>` element gets `muted="true"` and `soloed="true"` only when true (0024 P6). A reader refuses each attribute in a file of version 4 or lower, and a value that is not `true` or `false`.
- **Edit.** A change is an edit: one undo entry, an autosave, and refused during a take. The CLI has `dirigible track mute` and `track solo`, with `--off`.
- **Play.** During play, the Player crossfades the old mix to the new mix over the first chunk that it schedules after a mute or solo change of a track that is in both sessions. The ramp is linear, in output order, so a reverse play needs no special case. A track add or remove steps at the chunk boundary, as before. The change is heard after at most `Player.depth` chunks. The pending crossfade is in the `Feed`, so a dry restart keeps it, and a seek or a stop drops it. The real-time thread does not change.
- **Header.** M and S toggle buttons after Arm: mute on is a fixed systemBlue fill, solo on a systemYellow fill, never the accent color. The VoiceOver label names the track. Each row form shows them only from its measured width (`TrackRow.muteSoloWidth` on one line, `muteSoloTwoLineWidth` on two lines), so the route and the lost-device symbol keep their room. Option-click sets all tracks. Track > Mute Track (Shift-M) and Solo Track (Shift-S) act on the tracks of the range selection; no range or a clip set beeps (0038).
- **Notes.** The lanes of unheard tracks get a dim layer, with no lane redraw. The export panel shows one non-modal line when a track of the source is not heard, or a silent-file line. `dirigible export` and `render` print one `Warning: ` line on standard error for the same cases.

## Consequences

- A muted or soloed package does not open in a build of version 4 (0024 P3, as for fades).
- M and S are off during a take. No playback runs during a take today. The record monitor run must revisit this.
- One extra mix render runs for each change during play. A change is heard up to 0.3 s late, plus the output latency.

## Alternatives considered

- Window state: no format change, and it works during a take. The app export and the CLI export then differ, and a reopen loses the mute.
- Mute saved, solo window state: two homes for one rule, and solo still needs `--track` in the CLI to match an app export.
- A node restart at the heard frame on each change: the change is heard at once, but the stop and the play make a gap.
- A per-track ramp in `MixReader`: it works in the range order of `MixReader`, so a reverse play needs a flipped ramp, and the overlap of the interpolation span runs the ramp twice at a boundary.
