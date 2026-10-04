# 0035. Clip fades: session version 3, one quarter-sine curve, Command-F

- Status: accepted
- Date: 2026-10-03
- Accepted: 2026-10-03, after plan gates 1 and 2 of run `2026-10-03-clip-gain-fades` (part 11a).
- Amends: 0003 (fades from version 3; a fade of 0 is not written), 0016 (the mix has the fade factor), 0017 (the waveform has the fades), 0024 (the `session.xml` version table).
- Amended: 2026-10-04, run 11c-1. The 11c plan, the fade stop rule, and Command-F at a join point to 0036.

## Context

Release 2 run 11 asks for clip fades, a gain line, crossfades, and a clip inspector (F31, F32, F33, F84). The run splits in three parts: 11a (fades, this record), 11b (the mouse gain line, the fade handles, and the inspector), and 11c (crossfades). A fade is user data in `session.xml`, so an older build must refuse a file whose fades it cannot keep (0024 P3, P7). Probes of the run (Intel Mac, macOS 15): B1 measured `vvsinf` in Float within 1.3e-7 of the Double formula with an integer index ramp, and 3.6e-6 with a phase ramp. K1 found no Find item on Command-F, and a focused track name field ignores the key. P1 compared the fade line on the dB scale and on a linear scale.

## Decision

- **Fields.** A clip has `fades: Fades`, a value type with `fadeIn` and `fadeOut` in frames. `Fades.init?` refuses a negative length or a length over `Frames.limit`. `Session.check` refuses fadeIn + fadeOut over the clip length with `.fadeOutsideClip(clip, length:)`, for the reader and every edit.
- **Format.** `<clip ... fadeIn="480" fadeOut="960"/>`. The writer writes a fade attribute only when it is not 0, and a missing one reads as 0. `Session.fileVersion` is 3 when a clip has a fade, else 2 with an app route (0029), else 1. The reader refuses a fade attribute in a file of version 1 or 2 with `.invalidValue`.
- **Curve.** One curve, with no curve attribute. For clip frame k of a clip of N frames: fade-in `sin(pi/2 * k / I)` for k < I; fade-out `sin(pi/2 * (N - k) / O)` for k >= N - O, that is `cos(pi/2 * j / O)` with j the frames since the fade-out start. The first frame of a fade-in is 0, and the fade-out reaches 0 at the first frame after the clip. Half a fade is -3 dB (the Final Cut Pro +3 dB curve). A fade-out and a fade-in of one length sum to constant power, so a crossfade uses the same two functions on the sounding clip (0036). The curve has two copies: `Fades.gain(at:length:)` in Double, for the draw and the tests, and the vector `sineRamp` of `fadeEnvelope` in `MixReader`, for the render. `MixTests.theEnvelopeEqualsFadesGain` compares them across both fades.
- **Edits.** A cut part (split, clear, overwrite, excerpt) keeps only the fade of an edge of the clip that it keeps, fitted to its length. A trim keeps the fade of the edge that does not move, clamped to the new length; the fade of the moving edge is clamped to the new length minus that fade, so it can go to 0. When both edges move, the fade-in stays. `ClipEditTests.editsKeepTheFadeOfAKeptEdge` has the cases. A paste, a move, and a nudge keep the fades. `Session.setFades([ClipID: Fades])` sets many clips in one pass and one undo entry; a throw changes nothing.
- **Command-F.** Edit > Fade (Command-F, es "Fundido") acts on each clip on a selected track that overlaps the selection (`Marks.fades`). A range that holds the clip start (in <= start) gives a fade-in to the out point. A range that holds the clip end gives a fade-out from the in point. A whole clip gets min(0.5 s, length / 2) at each end. A range inside a clip does nothing. An edge at a butt join (a lane neighbor touches it) gets no fade. From 11c-2, a range with the join strictly inside makes a crossfade (0036). The new fade wins, and the other fade yields. No change gives a beep and no undo entry. A focused text field does not take the key.
- **CLI.** `dirigible clip fade <package> --clip <id> [--in <frames>] [--out <frames>]` calls `setFades`; an absent option keeps the current fade, and one option is required. `dirigible info` adds `fade in I, out O` to a clip line with a fade. `dirigible info --json` gives `fadeIn` and `fadeOut` on a clip only when not 0, as the XML does.
- **Render.** `MixReader`, the one mix of the Player and the export, multiplies a clip part with a frame in a fade by an envelope: gain times the fade factor. The envelope ramps the frame index inside each fade from an `Int` start, then scales it and takes `vvsinf`, so no clip frame above 2^24 becomes a Float. It is one reused buffer. A part with no fade frame keeps the plain gain path.
- **Draw.** The waveform of a column in a fade adds 20 log10 of the fade factor to its dB value. The factor is the maximum of the curve over the frames of the column, so a 0.5 s fade under one column at fit zoom keeps the column full. A column whose maximum is 1 computes nothing. In a clip box of 12 pt or more wide, a 1 px line in the label color marks the top of a 0 dBFS signal with the gains and the fade, on the same dB scale. On this scale a fade reads as a rounded corner (P1).
- **11b-1, landed.** In a clip box of 40 pt or more wide, a 1 px gain line continues the fade line with the fade factor 1: over 0 dB it stays on the top row, dashed 3 px on and 3 px off, and the clip label adds the gain. A filled 8 x 8 pt handle (inset 1 pt) sits at each fade end; an edge at a butt join with no fade has none. The zones in hit order: handle, the 4 pt trim (0020), the gain band (the line plus or minus 3 pt, only between the fades), the move zone, the range zone. A handle drag stops at the other fade. A double-click on the band gives 0 dB, and on a handle removes that fade. A text layer next to the pointer shows the gain in dB or the fade in ms during a drag. 11b-1 amends 0020.
- **11b-2, landed.** The inspector is a SwiftUI column of `SessionView` at the trailing edge (0023, amended): hidden by default, View > Show Inspector (Option-Command-I), an app preference. It shows Gain, Fade In, and Fade Out of the clips of `Marks.clipsToLevel`, and "Mixed" for different values. A typed gain clamps to -20...+20 dB and rounds to 0.1 dB. A typed fade is whole ms and stops at the other fade of each clip, as the handle does. The parse is strict and has no locale: Gain takes "." or "," as the decimal separator, and a fade takes digits only. A commit sets the clips of the draft, also after the Marks change, and `commitNames()` commits the draft first. `Session.setGains` sets many clips in one pass, and `dirigible clip gain` takes one or more clips.
- **11c, see 0036.** 0036 records the crossfade at a butt join, session version 4, the handle limit, and the drop of a crossfade at a broken join. The fade handle and the typed fade now stop at the room of the edge: the other fade, or half the crossfade at the other edge. An edge with a crossfade has no fade, and a fade yields to a crossfade. Command-F keeps this record's rule for a range that only touches a join.

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
