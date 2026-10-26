# 0060. Gain envelope, track roles, and ducking

- Status: accepted
- Date: 2026-10-18
- Accepted: 2026-10-18, after plan gates 1 and 2 of run `2026-10-18-envelope-ducking`.
- Amended: 2026-10-22, slice L3-S2. The threshold is a `Gain` in dBFS; the duck replaces points only inside the clip window, also with a range; a clip edge gets a point only when a kept point past it is not on the duck function.
- Amended: 2026-10-23, run `2026-10-23-read-by-time` (see 0062). `speechRuns` reads the window series of `mixLevels`, the scan of `silences` and `nearest_pause`. Each window starts at a multiple of 50 ms from session frame 0, so a ranged duck can read up to one window past each scope edge, and its runs are cut to the scope. A silence is the exact complement of the speech rule: a window at or under the threshold.
- Amended: 2026-10-26, run `2026-10-13-replace-roomtone-split` (see 0053). A split stereo moves a clip to another file: each point moves by the start of the run and the edge rule applies at the edges of the new file, so the gain at each source frame stays.
- Amends: 0003 and 0024 (session.xml version 10 with an envelope, version 11 with a role), 0035 (the fade factor multiplies the envelope factor), 0036 (the sounding clip reads the envelope in its handles; `canHeal` and so the **Seamless join** rule need equal gain at each frame of the joined range, envelopes included), 0016 (the mix applies the envelope; 0019 keeps its rule, as `MixReader` still reads `Session.heardTracks(in:)`), 0039 (the duck detection ignores mute and solo, as Auto Level), 0017 and 0022 (the gain line draws the envelope), 0011 (the new commands and tools).

## Context

A podcast tester (2026-10-16) could not lower an intro tune under the voice: a clip has one gain, and the fades exist only at the clip ends. The tester rendered the curve into a WAV with ffmpeg. Probe P1 of the run measured that curve: linear in dB, from 0 dB to -16 dB in 2.5 s, then flat; a stinger used the same -16 dB in 1.0 s. Release 7 asks for F75 (gain points per clip, ramps from a range gain), F72 (track roles), and F34 (ducking from the envelope and the roles). The reference apps: Hindenburg has no rubber bands; the user selects a range and drags the top line, and Duck makes fade handles (Journalist 1.21 guide pp. 31-32). Final Cut Pro adds keyframes at the edges of a range volume change, and Option-click adds a keyframe. Audition Auto-Duck and Audacity Auto Duck write volume keyframes that the user can then edit.

Rubric for the candidates:

1. Each edit of today (split, trim, move, ripple, crossfade, heal, paste, paste across rates) keeps the sound of an envelope with the least new code at the edit sites.
2. Auto Level and `clip_gain` keep their meaning.
3. Play, export, and draw cost stays O(points in the part), with no cost for a clip with no envelope.
4. An older build refuses the new data (0024 P3, P7) and a session with no new data keeps its version (P6).
5. A duck composes with the manual points and a second duck does not stack on the first.
6. An agent can set and read the envelope in timeline frames.

## Decision

### Envelope model (one-way: the meaning of a stored point)

`Clip.envelope: GainEnvelope`. A `GainEnvelope` is a sorted list of points `(frame: Frames, gain: Gain)`:

- `frame` is a **file frame** (the frame of the audio file, as `Clip.offset`), so a point stays on its audio. The envelope is a function of the file frames: a point can be anywhere in the file, and the clip window (`offset ..< offset + length`) only selects the part that plays. A move, a split, a trim, a ripple, a clear, a crossfade (the sounding clip reads its handles), and a paste at the same rate change no point. A paste at another rate scales each point (below).
- `gain` is a **relative** dB value on top of the clip gain. The clip gain line and Auto Level move the whole envelope and keep its shape.
- Between two points, the gain is **linear in dB**: g(f) = g0 + (g1 - g0) (f - f0) / (f1 - f0). Before the first point and after the last point, the gain holds the value of that point. An empty envelope is 0 dB everywhere.
- Invariant: the failable `GainEnvelope` initializer refuses frames that are negative or not strictly ascending, and a gain outside `Gain.range`. `Session.check` refuses a point after the end of the file (`frame <= file.length`), as it refuses a crossfade handle outside the file. A point outside the clip window is valid. The initializer keeps the points as given: an agent reads back what it set.
- **Edge rule** (range gain and duck, the two writes that compute a function on the file map): the corners of the function can lie before frame 0 or after the file length. The write drops each point outside `0...file length`. Then it puts one point at frame 0 and one at the file length, with the value of the function there, but only at an edge that had a dropped point beyond it and has no point yet. So at most one point sits at each edge, and the frames are strictly ascending by construction. Each write path (set, range gain, duck, paste) gives strictly ascending frames inside `0...file length`.
- `envelope` is a parameter of `Clip.init` with the default `.empty`, so a new clip from a file has no point. Each site in `Sources/` that builds a clip from another clip (cut, trim, ripple trim, paste, the sounding clip, the reader) passes it, and a paste at another rate scales it. The seeded `EnvelopeEditTests` is the guard.
- A cut (`Clip.cut`, split, trim, ripple trim, ripple delete, clear) keeps the whole list: split gives both parts the same list, and a cut adds no point. So an empty envelope stays empty, a split keeps the file version (0024 P6), and a trim that later extends the clip again plays the old points. Trim, ripple, clear, and the crossfade handles need no envelope code: each frame that plays keeps its gain because the function does not change.
- Heal (`ClipLane.canHeal`) keeps `a.gain == b.gain` and also needs equal envelope gain at each file frame of the joined range: from the sounding start of the left clip A to the sounding end of the right clip B, so a kept crossfade handle at an outer edge counts. Equal lists pass at once (the simple case: two parts of one split). Else the check compares the two functions at each point frame of both lists inside the range and at its two ends (exact `Double` equality), which is exact for piecewise-linear functions. An equal value at the join frame alone is not enough: two slopes through one value differ in the range. The healed clip takes the points of A before the join frame J and the points of B from J.
- `ClipLane.newCrossfadeChangesNoSample` stays `canHeal(after:)` and no crossfade at the join (0036 **Seamless join**). A crossfade at a seamless join reads only frames of the joined range, so it changes no sample only when the gain at each of those frames is equal, envelopes included: the envelope check of `canHeal` gives that. A join whose envelopes differ only outside a short crossfade takes the crossfade, which then changes no sample.
- A paste at another rate (`Excerpt.resampled`) scales each point frame with the offset rule, round(f x rate / old rate), and stops it at the end of the converted file. When two points fall on one frame, the first point stays.

Rejected: **clip-relative frames with absolute dB** (Final Cut Pro, where the keyframes are the volume line). Auto Level and `clip_gain` would have to rewrite every point; the sounding clip, a trim of the start, and heal would rebase each point. Rejected: **track automation on the timeline** (Logic, REAPER). Every clip edit (move, ripple, paste) would also have to edit the automation, and a moved clip would not take its envelope.

### Range gain

`Session.changeGain(by: Gain, in: Range<Frames>, on: [TrackID], ramp: Frames)` adds `d * w(f)` to the envelope of each clip that plays a frame of the widened range, where `w` is 1 inside the range, 0 outside `range` widened by `ramp` on each side, and linear in between. A sum of two piecewise-linear functions is piecewise linear, so the result is exact: the union of the old points and the four window corners. The ramps lie **outside** the range, so the whole range plays at the new gain. The sum works on the file map of each clip (timeline frame t is file frame t - start + offset, also outside the clip window), so a ramp that passes a clip edge goes on in the frames that do not play, and no point lands at a clip edge. A corner outside the file follows the edge rule of the envelope model. The default ramp is 500 ms (U4).

### Track role (one-way: a stored attribute)

`Track.role: Role?`, `enum Role: String { case dialogue, music, effects }`. No role is the default for every track, so an old session keeps its meaning. A role sets the color strip of the header and the default track lists of a duck. No role changes the sound.

### Ducking (one-way: baked points, not a live side chain)

A duck writes envelope points, as one edit and one undo step. Play and export do no detection.

- `DuckShape(depth: Gain, attack: Frames, release: Frames, threshold: Gain, hold: Frames)`, with the depth and the threshold under 0 dB and the lengths in frames, each checked at the CLI and tool boundary. Defaults: depth -16 dB (P1), attack 1000 ms, release 1000 ms, threshold -40 dBFS, hold 2000 ms (P2). Unknowns U5 to U8 of the run hold the evidence.
- Detection (`DirigibleAudio/DSP/SpeechActivity.swift`): the mix of the named speech tracks after the clip gain, the envelope, and the track gain, 50 ms RMS windows; a window over the threshold is speech; runs closer than `max(hold, attack + release)` merge, so two duck windows never overlap. The shortest pause that lets the music up is that larger value, not the hold alone.
- Detection ignores mute and solo, as Auto Level does (0031, 0039): a soloed music track or a muted speech track does not change the runs. `SpeechActivity` reads through `MixReader` a copy of the session with the mute and solo flags off, with the speech tracks as the track set, so `Session.heardTracks(in:)` stays the one owner of the heard rule.
- Zero speech runs in the scope is the named error `noSpeech` (exit 1): the duck writes nothing and keeps each envelope. The error text names the scope and the threshold.
- A missing, short, or unreadable speech file reads as silence, so the music stays up over its speech. The read returns the faults of `MixReader`, and the result and the `noSpeech` error name each such file: an `unread` line in the CLI and the tool text, and a warning banner with its path in the app.
- A music clip that no speech run reaches keeps its envelope. A run reaches a clip when the run widened by the attack before it and the release after it (`s - attack ..< e + release`) shares a frame with the clip window, in timeline frames. The duck writes nothing to a clip that no run reaches, and the report names that clip. So a fade that the user drew on an intro clip that no speech reaches stays.
- Shape (`DirigibleCore`, a pure function): for each speech run `s ..< e`, the music goes to `depth` from `s - attack` to `s` and back from `e` to `e + release`.
- Scope: the selection range, or the hull of a clip set, else the whole session. The scope of a clip set is its hull (`Selection.span`), from the first clip start to the last clip end, on the time axis only: the duck also works on a music clip in a gap between the set clips. The duck follows the speech, changes gain only, and is one undo entry, so the hull loses and copies no audio (the hull ban of 0038 covers Copy, Delete, ripple, and export). `Session.duckScope` cuts the range to the session end, so the duck reads no frame past the end; a range that starts at or after the end is the named error `duckRangePastEnd` (exit 1), and the duck writes nothing. The scope of a clip is the scope inside its clip window, so with a range too, no duck deletes a point outside the clip window. Inside the scope, the duck **replaces** the envelope of each music clip that a speech run reaches: a second duck does not stack, and a clip that no run reaches keeps its envelope. The duck works on the file map of each clip, as the range gain, so no point lands at a clip edge, and it follows the edge rule of the envelope model at the file ends. At a range edge inside the file map of a clip, the old value at the edge joins the duck shape with a 500 ms ramp inside the scope. With no range, the scope of each reached clip is its clip window: the duck replaces the points inside the clip window and keeps the points outside it, as the set does, so no duck deletes a point that `info` does not show. At a clip edge, the duck writes the nearest corner of its function past the edge, unless a kept point lies between: then a kept point on the function is enough, and else the duck puts one point at the clip edge with the value of the function. So the played frames follow the function, and a second duck gives the same envelope.
- Tracks: the speech tracks default to the dialogue-role tracks, and the ducked tracks default to the music-role tracks. The caller can name each list. There is no route fallback: a track with no role is in a list only when the caller names it. With an empty list, the duck fails with a named error and writes nothing. The app sheet prefills its checklists from the roles only. On an open session, the `duck` tool runs as a long job with progress and Cancel (0049).

Rejected: **a live side chain at play and export** (GarageBand 09 ducking, which GarageBand 10 dropped). The detection runs at each play, the play and the export need a look-ahead, the user cannot edit the result, and the CLI cannot read it.

### Render path

`MixReader.render` multiplies the fade factor of 0035 and 0036 by the envelope factor, in the factor buffer of the part, with a second buffer for the fade factors when the part also has a fade. For each run of frames between two points in the part, it computes the dB of the run start in `Double` and ramps the index from the run start with `vDSP_vramp`, so no file frame becomes a `Float` (the B1 rule of 0035). Then `10^(dB/20)` is `vvexpf(dB * ln(10) / 20)`, with the clip and track gain added in dB. A part with no envelope point and no fade keeps the one-gain `vDSP_vsma` path. The Player and the export read the same code, so play equals export.

### Draw

`ColumnFades` gets the envelope: the factor of a column is the maximum of the envelope over its frames, added in dB to `columnGain`, so the waveform draws after the envelope and no peak hides. A binary search finds the first point of the draw rect. The gain line becomes the clip gain plus the envelope, 1 px, dashed above 0 dB. Points are 6 pt discs in the label color, drawn only in clip boxes of 40 pt or more and only where both neighbors are 8 pt or more away.

### Format

```xml
<track id="..." name="Music" gain="0" layout="stereo" role="music">
  <clip id="..." file="..." start="0" offset="0" length="864000" gain="0">
    <envelope>
      <point frame="144000" gain="0"/>
      <point frame="264000" gain="-16"/>
    </envelope>
  </clip>
</track>
```

`session.xml` is version 10 when a clip has an envelope point, and version 11 when a track has a role (the higher rule wins, as in `Session.fileVersion`). The reader refuses `<envelope>` in a file of version 9 or lower, and `role` in a file of version 10 or lower. A negative frame, a frame after the end of the file, a frame that is not ascending, or a gain that is not finite is a damaged file (a point outside the clip window reads); a gain outside `Gain.range` is clamped, as for the clip gain.

### CLI and MCP (0011)

| Command | Tool | Does |
|---|---|---|
| `clip envelope <pkg> <clip> --point <frame>:<dB> ...` and `--clear` | `clip_envelope(clip, points: [[frame, db], ...])` | Sets the envelope inside the clip. A frame is a timeline frame inside the clip. The new list replaces only the points inside the clip window and keeps the points outside it, so no call deletes a point that `info` does not show. An empty list clears the points inside the window. |
| `clip gain-range <pkg> --track <t> ... --from <f> --to <f> --db <d> [--ramp <frames>]` | `clip_gain_range(track, from, to, db, ramp)` | The range gain. |
| `track role <pkg> <track> <dialogue\|music\|effects\|none>` | `track_role(track, role)` | Sets the role. |
| `duck <pkg> [--speech <t>]... [--music <t>]... [--from <f> --to <f>] [--depth --attack --release --threshold --hold]` | `duck(...)` | The duck, with a report of the speech runs, the points written, and the clips it kept because no run reaches them. |

`info` and `session_info` show the role of each track and the envelope points of each clip in timeline frames: the points inside the clip window, and the count of the points outside it. `info --json --compact` shows the point count only.

## Consequences

- A clip of a newer file with an envelope opens in an older build as "made by a newer version" and stays unchanged.
- The per-clip `loudness` measure and Auto Level read the clip gain and not the envelope. Export loudness reads the mix, so it includes the envelope.
- A trim keeps the points outside the new window. A later trim that extends the clip plays them again. No primary source says what Final Cut Pro does with keyframes in a trimmed part (Mac guide 12.4, iPad guide 3.4, FCPXML reference: research section 2.5), so this rule is a decision of this run, not a copy of FCP.
- Heal with different gains (backlog) can now keep the gain step as two envelope points one frame apart.
- The duck replaces the points that a user drew inside its scope and inside the clip window, on each music clip that speech reaches; the points outside the clip window stay. A clip that no speech reaches keeps its points. The sheet says so, and Undo restores the replaced points.

## Alternatives considered

The rejected candidates are under each part.
