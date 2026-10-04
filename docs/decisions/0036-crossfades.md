# 0036. Crossfades at a butt join: session version 4, paired lengths on both clips, the sounding clip

- Status: accepted
- Date: 2026-10-04
- Accepted: 2026-10-04, after plan gates 1 and 2 of run `2026-10-04-crossfades` (part 11c-1).
- Amends: 0003 (crossfades from version 4), 0016 (the mix reads the sounding clip), 0017 (the waveform and the X line, 11c-2), 0020 (the crossfade handles, 11c-2; the fade handle stops at the room), 0024 (the `session.xml` version table), 0035 (the 11c plan, the fade stop rule).

## Context

Release 2 run 11 asks for crossfades (F33). Decision 0035 planned them: an equal-power crossfade at a butt join, centered on the join, with no overlap of clips, from the media handles, in `session.xml` version 4. It left two questions open: a handle that is too short, and a crossfade at a join that an edit breaks. Hindenburg makes a crossfade from a selection with Command-F and changes its length with a handle drag. Logic Pro pivots a crossfade on the region junction. Final Cut Pro offers an overlap (a ripple edit) when the handles are short. Probe X1 measured the Float ramp of `sineRamp`: |a^2 + b^2 - 1| <= 2.2e-7 for L = 1 to 96,001 frames. The run splits in two parts: 11c-1 (the model, the format, the CLI, and the render) and 11c-2 (Command-F at a join, the handle drag, the draw, and the benches).

## Decision

Notation: clip A ends at the join J, and clip B starts at J. L is the crossfade length.

- **Fields.** A clip has `crossfades: Crossfades`, apart from `fades`, with a `start` and an `end` length in frames. `Crossfades.init?` refuses an odd length, a negative length, and a length over `Frames.limit`. 0 is no crossfade. At a join, A.crossfades.end equals B.crossfades.start, so each clip holds its own half and the render and the draw need no neighbor lookup. The 11b-1 handle and the 11b-2 inspector rebuild `Fades`, so a separate field keeps them from dropping a crossfade.
- **Sounding clip.** `Clip.sounding` is the clip as it sounds: L/2 frames of media handle more at each edge with a crossfade, and the crossfade of that edge as the fade of that edge. `Fades.gain` and the `fadeEnvelope` of `MixReader` run on it with no change, so the 0035 curve gives a(i) = sin(pi/2 * (L - i) / L) and b(i) = sin(pi/2 * i / L).
- **Format.** `<clip ... crossfadeOut="960"/>` on A and `<clip ... crossfadeIn="960"/>` on B. The writer writes each attribute only when it is not 0, and a missing one or a written 0 reads as 0. `Session.fileVersion` is 4 when a clip has a crossfade, else the 0035 rule. `sessionVersion` is 4. The reader refuses:
  - a crossfade attribute in a file of version 3 or lower, and an odd, negative, or too long value, with `.invalidValue`;
  - a crossfade with no touching partner, or two partners of different lengths, with `.crossfadeWithoutJoin`;
  - a crossfade at a seamless join with `.crossfadeAtSeamlessJoin`;
  - a fade and a crossfade at one edge with `.fadeAtCrossfade`;
  - a short media handle with `.crossfadeOutsideFile(clip, needed: L/2)`.
- **Media-handle limit.** `Session.check` refuses a clip with less than L/2 frames of file before its start crossfade (L/2 <= offset) or after its end crossfade (offset + length + L/2 <= file length), with `.crossfadeOutsideFile(clip, needed: L/2)`. It refuses a fade at an edge with a crossfade with `.fadeAtCrossfade`. There is no overlap and no ripple: `MixReader` cuts a short read with no error, which is an audible dip. `crossfadeLimit(after: A)` is 2 x min(handle after A, handle before B, room of A, room of B), rounded down to even. It is 0 at a seamless join, and nil when no clip touches the end of A or the file of A is not in the pool. Command-F and the handle drag of 11c-2 clamp to it.
- **Room.** The reach of an edge is its fade plus half its crossfade. `Clip.room(edge)` is the length minus the reach of the other edge, with no special case. `Session.check` refuses reach(start) + reach(end) over the length with `.fadeOutsideClip`. The fade handle, the inspector, and `Clip.fades(setting:to:)` clamp a fade to the room of its edge, and give no fade at an edge with a crossfade. A fade yields to a crossfade: `Clip.fitting` fits the fades into the length minus both crossfade halves. In `crossfadeLimit`, the room counts the crossfade half at the other edge and not its fade, because that fade yields.
- **Set.** `Session.setCrossfades([ClipID: Frames])` takes the left clip of each join. L > 0 sets the crossfade on both clips, sets the fades at the two join edges to 0, and makes the fade at the other edge of each clip yield. L = 0 removes the crossfade from both clips and leaves the fades. A clip with no touching right neighbor throws `.crossfadeWithoutJoin`, also for L = 0. L > 0 at a seamless join throws `.crossfadeAtSeamlessJoin`. A length that `Crossfades` refuses throws `.frameOutOfRange`, and an unknown clip `.unknownClip`. It checks each changed clip, then writes all the changed clips of a lane before the repair reads their joins, so a crossfade of two clips is never half written. One pass and one undo entry; a throw changes nothing.
- **Drop at a broken join.** An edit that breaks a join removes the crossfade from both clips. `ClipLane` keeps a crossfade only when its neighbor touches the edge, both lengths are equal, and the join is not seamless. `clear`, `split`, `overwrite`, and `remove(ids:)` end with a repair of the whole lane, because they cut or remove clips that can leave an orphan on a clip that the edit did not touch. `insert` repairs the joins next to each inserted clip, and `remove(at:)` repairs the join of its two new neighbors. This is complete because every mutator leaves the lane paired and every clip has a positive length. `replace(at: i)` repairs only the joins of clips i - 1 to i + 1: one clip changes and no clip moves, so `setFades`, `setGains`, and `setCrossfades` stay linear. A cut part (split, clear, overwrite, excerpt) keeps the crossfade of an edge of the clip that it keeps only when its half is not more than the room of that edge; the repair then drops the partner. A trim keeps the crossfade of each edge that does not move, and the fades yield to it. A paste, a move, and a nudge keep the crossfades; the repair drops each one whose join does not come with it. A move to the same track and start, and a nudge by 0, change nothing. `CrossfadeTests.randomEditsKeepTheSessionSavable` runs 500 seeded edit sequences, and each saved session reads back.
- **Seamless join.** A join is seamless when B is in the file of A at offset A.offset + A.length. There the handles of A and B hold one signal, and equal power makes it 3 dB too loud at J. The join plays with no seam already, so the model refuses a crossfade there and Command-F skips it.
- **CLI.** `dirigible clip crossfade <package> --clip <A> --length <frames>` calls `setCrossfades`; `--length 0` removes it. The parser refuses an odd or negative length with exit 64. `dirigible info` adds `crossfade in L` or `crossfade out L` to a clip line, and `info --json` gives `crossfadeIn` and `crossfadeOut` only when not 0. `crossfadeLimit` does not change a session, so it has no command.
- **Errors.** The CLI gives each new case its own text. The window does not make an edit that throws one of the four cases, so the app shows the `errorSessionOther` text for each.
- **Render.** `MixReader`, the one mix of the Player and the export, finds a clip by its sounding range and renders the sounding clip. A render from J + 1 includes the end of A. The media check of an export reads the files of the sounding clips too.
- **11c-2, as planned: Command-F.** A range with in < J < out on a selected track makes a crossfade of L = 2 x min(J - in, out - J), centered on J, clamped to `crossfadeLimit`. A range that holds A and B whole (Select All) gives 20 ms (960 frames at 48 kHz), rounded to even. A range that only touches J keeps the 0035 rule (no fade at a butt join). A limit of 0 skips that join, and no change gives a beep. One Command-F sets the crossfades first, then the fades of 0035 fitted to the room, in one undo entry.
- **11c-2, as planned: handles.** A crossfade shows two 8 x 8 pt handles, at J - L/2 in A and at J + L/2 in B. A drag of either handle sets L = 2 x the distance to J, clamped to `crossfadeLimit`; a drag to J removes it. A double-click on a handle removes it. The readout shows "Crossfade N ms". A join with no crossfade has no handle, so no drag makes a new crossfade. The drag is a new path of the 0020 budget, measured by its own bench.
- **11c-2, as planned: draw.** The waveform of each clip takes its own half of the curve, so a 0 dBFS column at J is 3 dB under the top. The fade line of each clip continues over its handle into the neighbor box, in the controls pass after the waveforms, so the two lines cross at J as an X. The lane draw query and `changedFrames` use the sounding range. Until 11c-2 lands, the lanes do not draw a crossfade.

## Consequences

- A build that reads version 3 or lower refuses a session with a crossfade. A session with no crossfade keeps its version 1, 2, or 3 text.
- A clip edit can remove a crossfade with no message. Undo restores it.
- Until 11c-2 lands, only `dirigible clip crossfade` makes a crossfade, and the lanes do not show it.
- An asymmetric crossfade, a moved pivot, or another curve needs a new attribute and a version bump.

## Alternatives considered

- A crossfade stored on one clip: rejected, every edit and `changedFrames` would need a neighbor rule.
- A crossfade inside `Fades`: rejected, the fade handle and the inspector rebuild `Fades` and would drop it.
- An odd L with floor(L/2) before J: rejected, every UI path gives an even L, and an odd one needs a split rule.
- An overlap or a ripple edit when the handles are short (Final Cut Pro): rejected, 0035 forbids an overlap of clips.
- An asymmetric crossfade, or a pivot moved with Command-drag (Hindenburg): rejected, the crossfade stays centered on J (0035).
- A shorter crossfade in place of the drop when a split falls inside a reach: rejected, a drop keeps one rule for every broken join.
- A repair of only the changed clips, with no neighbors, or a local repair after an edit that removes clips away from its window: rejected, it leaves an orphan on an untouched neighbor, and every later save fails.
- A handle at every join that makes a crossfade by drag: rejected, it covers the trim zones at each speech edit.
- A shaded band or a waveform of the handle audio in the draw: rejected, a band costs a Swift loop per pixel.
