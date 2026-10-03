# 0035. Clip fades: session version 3, one quarter-sine curve, Command-F

- Status: accepted
- Date: 2026-10-03
- Accepted: 2026-10-03, after plan gates 1 and 2 of run `2026-10-03-clip-gain-fades` (part 11a).
- Amends: 0003 (fades from version 3; a fade of 0 is not written), 0016 (the mix has the fade factor), 0017 (the waveform has the fades), 0024 (the `session.xml` version table).

## Context

Release 2 run 11 asks for clip fades, a gain line, crossfades, and a clip inspector (F31, F32, F33, F84). The run splits in three parts: 11a (fades, this record), 11b (the mouse gain line, the fade handles, and the inspector), and 11c (crossfades). A fade is user data in `session.xml`, so an older build must refuse a file whose fades it cannot keep (0024 P3, P7). Probes of the run (Intel Mac, macOS 15): B1 measured `vvsinf` in Float within 1.3e-7 of the Double formula with an integer index ramp, and 3.6e-6 with a phase ramp. K1 found no Find item on Command-F, and a focused track name field ignores the key. P1 compared the fade line on the dB scale and on a linear scale.

## Decision

- **Fields.** A clip has `fades: Fades`, a value type with `fadeIn` and `fadeOut` in frames. `Fades.init?` refuses a negative length or a length over `Frames.limit`. `Session.check` refuses fadeIn + fadeOut over the clip length with `.fadeOutsideClip(clip, length:)`, for the reader and every edit.
- **Format.** `<clip ... fadeIn="480" fadeOut="960"/>`. The writer writes a fade attribute only when it is not 0, and a missing one reads as 0. `Session.fileVersion` is 3 when a clip has a fade, else 2 with an app route (0029), else 1. The reader refuses a fade attribute in a file of version 1 or 2 with `.invalidValue`.
- **Curve.** One curve, with no curve attribute. For clip frame k of a clip of N frames: fade-in `sin(pi/2 * k / I)` for k < I; fade-out `sin(pi/2 * (N - k) / O)` for k >= N - O, that is `cos(pi/2 * j / O)` with j the frames since the fade-out start. The first frame of a fade-in is 0, and the fade-out reaches 0 at the first frame after the clip. Half a fade is -3 dB (the Final Cut Pro +3 dB curve). A fade-out and a fade-in of one length sum to constant power, so 11c uses the same two functions with no offset. The curve has two copies: `Fades.gain(at:length:)` in Double, for the draw and the tests, and the vector `sineRamp` of `fadeEnvelope` in `MixReader`, for the render. `MixTests.theEnvelopeEqualsFadesGain` compares them across both fades.
- **Edits.** A cut part (split, clear, overwrite, excerpt) keeps only the fade of an edge of the clip that it keeps, fitted to its length. A trim keeps the fade of the edge that does not move, clamped to the new length; the fade of the moving edge is clamped to the new length minus that fade, so it can go to 0. When both edges move, the fade-in stays. `ClipEditTests.editsKeepTheFadeOfAKeptEdge` has the cases. A paste, a move, and a nudge keep the fades. `Session.setFades([ClipID: Fades])` sets many clips in one pass and one undo entry; a throw changes nothing.
- **Command-F.** Edit > Fade (Command-F, es "Fundido") acts on each clip on a selected track that overlaps the selection (`Marks.fades`). A range that holds the clip start (in <= start) gives a fade-in to the out point. A range that holds the clip end gives a fade-out from the in point. A whole clip gets min(0.5 s, length / 2) at each end. A range inside a clip does nothing. An edge at a butt join (a lane neighbor touches it) gets no fade, so 11c does not change what the key does there. The new fade wins, and the other fade yields. No change gives a beep and no undo entry. A focused text field does not take the key.
- **CLI.** `dirigible clip fade <package> --clip <id> [--in <frames>] [--out <frames>]` calls `setFades`; an absent option keeps the current fade, and one option is required. `dirigible info` adds `fade in I, out O` to a clip line with a fade. `dirigible info --json` gives `fadeIn` and `fadeOut` on a clip only when not 0, as the XML does.
- **Render.** `MixReader`, the one mix of the Player and the export, multiplies a clip part with a frame in a fade by an envelope: gain times the fade factor. The envelope ramps the frame index inside each fade from an `Int` start, then scales it and takes `vvsinf`, so no clip frame above 2^24 becomes a Float. It is one reused buffer. A part with no fade frame keeps the plain gain path.
- **Draw.** The waveform of a column in a fade adds 20 log10 of the fade factor to its dB value. The factor is the maximum of the curve over the frames of the column, so a 0.5 s fade under one column at fit zoom keeps the column full. A column whose maximum is 1 computes nothing. In a box of 12 pt or more, a 1 px line in the label color marks the top of a 0 dBFS signal with the gains and the fade, on the same dB scale. On this scale a fade reads as a rounded corner (P1).
- **11b, as planned.** The mouse zones of a clip in hit order: an 8 x 8 pt fade handle at the end of each fade, the 4 pt trim (0020), a gain band of the line plus or minus 3 pt (drag up or down; a double-click gives 0 dB), the move zone, the range zone (the lower third, 0020). Handles and the gain band show only in boxes of 40 pt or more. The inspector is the trailing pane that 0023 plans: hidden by default, View > Show Inspector (Option-Command-I), with Gain (-20 to +20 dB) and Fade In and Fade Out in ms. 11b amends 0020.
- **11c, as planned.** An equal-power crossfade at a butt join, centered on the join, with no clip overlap: the render reads L/2 frames of media handle past the end of the left clip and before the start of the right clip. Both clips store the crossfade, so `changedFrames` redraws both. It raises `session.xml` to version 4, and 11c decides the handle shortfall and the drop of a crossfade at a broken join.

## Consequences

- A build that reads version 2 or lower refuses a session with a fade. A session with no fade keeps its version 1 or 2 text.
- Auto Level (0031) and `dirigible loudness` measure a clip with its gain and no fade. The export and the loudness strip measure the mix, so they include the fades.
- A Command-F on Select All at 2 h changes every clip with no butt join, so the lanes draw again in full. That draw takes about 28 ms on the Intel Mac, as a Select All Nudge does. The bench asks that Command-F costs no more than that nudge.
- Another fade curve needs a new attribute and a version bump.

## Alternatives considered

- Plain `fadeIn` and `fadeOut` fields on `Clip`: rejected, the curve and the yield rules would spread over the model, the timeline, and the renderer.
- Child elements with an optional crossfade link: rejected, more parse code now; 11c adds attributes with version 4.
- The crossfade field in version 3: rejected, 11a would need the join and handle rules in every lane edit (0024 P7).
- A reserved curve attribute: rejected, a newer curve value needs a version bump anyway.
- A phase ramp in the envelope: rejected, 3.6e-6 error against 1.3e-7 for the index ramp (B1).
- A linear fade line: rejected (P1), speech peaks stand above it, and the waveform and the line would use two scales.
- A popover inspector: rejected for the 0023 pane, because a popover closes while the user works on many clips.
