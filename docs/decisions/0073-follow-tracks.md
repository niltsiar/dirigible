# 0073. Follow tracks: a track flag in session.xml version 16, whole-clip moves in a ripple, and a refusal on overlap

- Status: accepted
- Date: 2026-11-07
- Amends: 0003 (the track attribute `follow`), 0024 (the version table: version 16 with a follow track), 0037 (the ripple of a follow track), 0020 (the ripple trim drag stops at the last event before a follow overlap), 0011 (`dirigible track follow`, the tool `track_follow`, and the overlap text), 0018 (`Marks.pasteTracks` pastes on the source tracks after a default selection).

## Context

A ripple (0037) cuts every scope track at the range edges. On a music bed or an effects track, the cut makes the music jump and leaves short pieces. F70 asks for a follow track: "in a ripple, its clips move whole and never split" (`docs/requirements/features.md`).

- **Final Cut Pro.** A range delete does not cut a connected clip: "the connected items are not deleted but are instead shifted to the closest primary storyline clip" ([RM], `docs/research/timeline-edits.md` section 4). FCP lanes stack, so FCP has no collision rule. No source states what FCP does when two connected clips land on one time (unconfirmed).
- **Hindenburg PRO.** No follow track. Cut acts on the tracks of the selection (`docs/research/ripple-edit.md` section 6, [HSC]). A music track out of the selection stays where it is; 0037 rejected that scope as the default ("it breaks the sync of the other voices with no warning").
- **Logic Pro.** No follow track. The No Overlap drag mode shortens the earlier region at an overlap ([LDM], `docs/research/timeline-edits.md` section 1).
- **REAPER (context).** A locked item in a ripple can "interrupt the ripple, interrupt it per track, stay unaffected, or ignore the lock" (`docs/research/ripple-edit.md` section 6, [RG]). No rule moves an item whole.
- **Dirigible.** A `ClipLane` cannot stack clips: "No two clips overlap" (`ClipLane.swift`). A track flag of 0039 is `muted="true"` and `soloed="true"`, written only when true, read by `XMLElement.flag` (`SessionReader.swift`): a value that is not `true` or `false` refuses, and so does the attribute in a file of version 4 or lower.

## Rubric

1. No ripple of an existing session changes with no act of the user.
2. One owner of the rule: Core, so the window, the CLI, the tools, the transcript cut, the silence tool, and Replace give the same result.
3. A refusal changes nothing and names the clips.
4. The fewest new formats, new rules, and new UI surfaces.
5. The CLI and the tools can set and read the state (0011 **CLI parity**).

## Candidates

### A. A stored track flag (chosen)

`Track.isFollowTrack: Bool`, set by `Session.setFollowTrack(_:tracks:)`. The ripple mutators of `Session+Ripple.swift` read the flag of each scope lane.

- Rubric: 1 yes (default off). 2 yes. 3 yes. 4 one attribute, one version, one menu item, one header mark. 5 yes: `dirigible track follow`, `track_follow`, `info`.

### B. Follow derived from the role

A track with the role music or effects (0060) follows. No new attribute.

- Rubric: 1 no: every session with a music role ripples in a new way after the update, with no act. 2 yes. 3 yes. 4 best: no format change. 5 yes through `track role`.
- Red flag (split ownership): one stored value (the role) owns two policies, the duck default and the ripple. A user who wants a dialogue-only track to follow (for example a phone insert) cannot.

### C. A per-edit option, nothing stored

Each ripple call takes `follow: [TrackID]`. The window keeps a per-user set in `UserDefaults`, and the CLI takes `--follow <track>`.

- Rubric: 1 yes. 2 no: the window state and each CLI or tool call hold the list in two places, so an agent edit of an open session ripples the music bed differently from a window edit. 3 yes. 4 no format change, but a flag on each ripple command and tool (5 commands, 5 tools, and the transcript and silence paths). 5 partial: the package does not hold the state.
- Red flag (split ownership and two ways to do one task).

### The format of A

- **A1. `follow="true"`, the 0039 flag form (chosen).** The reader uses the one flag rule of `<track>`: `XMLElement.flag` takes the first version of the attribute as a parameter, so `muted`, `soloed`, and `follow` share one parse.
- **A2. `follow="1"` (the first draft).** Rejected: a second spelling of a Boolean on one element, and a second parse rule.
- **A3. A `ripple="follow"` word attribute, open to more words later (for example a track that a ripple never moves).** Rejected now: one state exists, and a later word is a new value that raises the version anyway (0024 P7), so the word form buys nothing today.
- **A4. A `<follow/>` child element.** Rejected: a child element holds structure; a track flag is an attribute in 0003 and 0039.

## Decision

- **Model.** `Track.isFollowTrack: Bool`, `public internal(set)`, default false. The app has `timeline.follows` for Automatic Scroll, so the Core name is `isFollowTrack`. `Session.setFollowTrack(_ on: Bool, tracks: [TrackID]) throws(SessionError)`: an unknown track throws `.unknownTrack` and changes nothing, as `setMuted`. Split Stereo copies the flag to both new tracks, as it copies mute, solo, and role.
- **Format.** `<track ... follow="true">`, written only when true (0024 P6). `Session.fileVersion` is 16 when a track follows, else the rule of the lower versions. `package let followSessionVersion = 16`, and `sessionVersion` is `followSessionVersion`.
- **Read of an older file.** A file of version 15 or lower has no `follow`, so each track reads as not following, and the ripples of that session do not change (rubric 1). The reader refuses `follow` in a file of a version lower than 16, and a value that is not `true` or `false`, with `.invalidValue(element: "track", attribute: "follow")`. `follow="false"` reads as false, and the next save writes no attribute (as `muted`).
- **Read of a newer file by an older build.** A build with `sessionVersion` 15 refuses a version 16 file with `.unsupportedVersion(16)` and changes nothing (0024 P3, P4).
- **Named lanes.** A lane that the edit names edits as a normal lane, also with the flag: in the window, a track that the user chose (a track selection, or a range drawn on its lane), the tracks of the words of a transcript selection, and the tracks of the "in Selected Tracks" items; the `--track` list of the CLI and the `track` list of the tools (no list names none); the tracks of the cut words; and the paste targets of Insert and Replace. A transcript selection holds each track that does not follow and the track of each selected word, so the window and `dirigible transcript cut` cut the same lanes. A selection on all tracks by default names none: a ruler drag, I and O, Select All, or a silence row with no selected track. The window holds that state as `Marks.tracksByDefault`, and `Marks.rippleScope` gives the named set, empty for it. A paste on such a selection goes to the source tracks of the excerpt when each is in the session, else to the first selected track and the tracks under it (0018), so a Cut and an Insert at the same place restore the lanes. The silence edits and the ripple trim drag name none (the drag edits its own track with `ClipLane.ripple` already). The follow rule below moves only the other lanes of the scope. So Cut of a follow track removes what it copies, a cut word goes from its own track, and a paste never clears the frames of a follow clip. Core gets the set as `naming: [TrackID]` on the public `rippleDelete`, `rippleInsert`, and `rippleTrim` (default none), as the paste targets of `replace` and `paste(_:mode:on:)`, and from the tracks of the clips of the named words in `cutWords` (`WordOccurrence.clip`); the two internal lane loops read it. `Session.cuttingTracks(_:naming:)` gives the lanes that cut (each lane that does not follow or that the edit names). The excerpt of a Cut holds only those lanes, so a follow lane that follows never reaches the clipboard.
- **No lane cuts.** When the scope has a lane and none of its lanes cuts (each follows, and the edit names none), the public `rippleDelete` and `rippleInsert` throw `.noRippleTrack` and change nothing, so no edit only moves clips. The check comes after the guards for no range and for a length of 0, so a silence Apply with only Mark and Mute rows passes. `rippleTrim` never throws it: the lane of the trimmed clip always edits. Replace, the paste insert, and `cutWords` always name a lane.
- **Ripple delete on a follow lane.** No clip splits. Each clip start maps through `Frames.afterRippleDelete(of:)`, the Rule M function of 0037: a start at or after the end of a range moves left by the removed frames, a start inside a range goes to the range start, and a start at or before the range start stays. A clip over a range edge so stays whole. The map keeps the order, so one pass over the adjacent pairs finds an overlap. An overlap throws `.followOverlap(<the later clip>, <the earlier clip>)`, and the whole edit changes nothing, also on the other tracks. With no overlap, each touching pair stays touching (a probe over 135,359 random legal deletes, and `FollowRippleTests.aLegalFollowDeleteKeepsEachJoin`), so no crossfade breaks; the mutator ends with the repair of `ClipLane` anyway.
- **Ripple insert on a follow lane.** No split: each clip that starts at or after the frame moves right by the length (`ClipLane.shift(from:by:)`). A clip over the frame stays. An insert never overlaps. An insert inside the first clip of a touching pair moves only the second clip, so the join opens and both clips lose its crossfade (0036), as at a join of a normal lane.
- **Ripple trim.** The own track keeps `ClipLane.ripple(at:with:)`, whose later clips already move whole. The other scope lanes get the span delete or insert, so the follow rule applies to them too. The ripple trim drag keeps the last preview when a drag event throws (0020, `Gesture+Clip.swift` `rippleDrag`), so the edge stops at the last event that did not overlap, and the mouse-up commits that preview.
- **One owner.** The follow branch is in the two internal lane loops of `Session+Ripple.swift` (`rippleDelete(_:lanes:taken:)`, `rippleInsert(_:at:lanes:taken:)`). Every ripple goes through them: the Edit and lane menu ripples, Insert, the paste insert, Replace (0053), the transcript cut (0055), the silence plan (0066), the ripple trim, the CLI, and the tools. Each caller passes its named lanes to them, so the paste after an insert finds an empty gap on each target.
- **Error.** `SessionError.followOverlap(ClipID, ClipID)`: the clip that would move onto the other clip, then the other clip. `.overlap` stays the refusal of a damaged file or a bad edit; the window shows it as a bug (`L10n+Messages.swift`). The CLI and tool text: `clip "<a>" follows ripples and would cover clip "<b>".` The window shows the overlap alert of U-L3b with the track and the start of the first clip. `SessionError.noRippleTrack`, the form of `.noSpeechTrack` and `.noDuckedTrack` (no payload): the CLI and tool text `no track to edit: each track of the ripple follows ripples, and the edit names none.`; the window shows the error alert with its own text ("Each track follows ripples, so nothing would be cut. Turn off Follow in Ripples on the track to cut."; the silence Apply names no track, so the text gives only that fix). `.nothingToCut` stays the refusal of a cut of words with no audio.
- **Markers.** Rule M does not change: a marker moves as before, so a marker and a follow clip that started at one frame inside a range both go to the range start.
- **CLI and tools.** `dirigible track follow <package> <track>... [--off]`, the form of `track mute`: no track exits 64, an unknown track exits 1. The tool `track_follow` with `tracks` and `off`, as `track_mute`, a batch step. `info` adds ` follow` to the track line, and `info --json` gives `"follow": true` only when true.

## Usage (caller's view)

```swift
try session.setFollowTrack(true, tracks: [music])          // one undo entry in the window
try session.rippleDelete(5 * 48_000 ..< 7 * 48_000, on: session.tracks.map(\.id))
// The dialogue lanes are cut and closed. The music lane: no clip is cut;
// a clip at or after 7 s moves left by 2 s, a clip that starts in the range
// moves to 5 s, a clip that starts at or before 5 s stays.
// A moved clip that would cover a clip throws .followOverlap(moved, covered).
```

## Consequences

- A version 16 package does not open in a build that reads version 15 or lower (0024 P3), as for each bump.
- A follow clip that starts in the cut moves to the cut start, so its audio plays earlier than its old place relative to the speech after the cut. FCP does the same.
- A long follow clip over the cut stays whole, so after the ripple it runs past the speech by the cut length. The user trims it.
- Two touching follow clips (a split music bed) refuse a cut inside the first clip: the second clip moves onto the first. A cut that starts at the join passes. The alert gives "Turn Off Follow in Ripples" as the fix in one click.
- An overlap refuses the whole ripple, also on the dialogue tracks.
- A ruler drag, or I and O, with no selected track lets each follow track follow, so the guide workflows "Remove a mistake" and "Remove a mistake and close the gap" keep the music bed whole. A range drawn on a follow lane, a lane drag over it, a header click on it, or a selection of its words in the transcript names it, so it cuts. The guide says both. Reverse: name the selected tracks of each window range (drop `Marks.tracksByDefault`), so a range on every track cuts the follow tracks too.
- A lane drag added to a range on all tracks by default (Shift-Command) names each track, so a follow track in it cuts. A Command-click on its lane takes it out.
- A session where each track follows refuses a ripple with no named track (`.noRippleTrack`); the user turns off Follow in Ripples on one track, or, in the window, selects a track or draws the range on its lane.
- A paste on a selection on all tracks by default goes to the source tracks of the excerpt, also in a session with no follow track, so after Select All an excerpt of the second track pastes on the second track, not on the first. A selection that the user chose keeps the 0018 rule. Reverse: map from the first selected track for each selection (the 0018 rule), so a paste after a default selection can put a speech lane on a follow track above it.
- A ripple trim drag over a follow track that does not move keeps the region copy of 0037: `shiftedFrames` names each lane whose clips do not change, and that lane keeps its pixels and draws only the lines of the markers that change (amends 0022). A follow lane that moves by another delta than the cut lanes, or that changes and does not move, gets no region copy, so the lanes draw in full (0037 measured a full draw at p95 23.6 ms). `MouseEventRippleBenchmark` has a row with a whole-session follow bed that checks the 16 ms budget of 0020.

## Alternatives considered

- B and C above, and the formats A2 to A4.
- On overlap, the moved clip overwrites the clip under it: rejected, it cuts a clip, which F70 forbids.
- On overlap, the earlier clip is shortened (Logic No Overlap): rejected, a follow clip loses audio with no message, and F70 says the clips move whole.
- On overlap, the later clips push right until they fit: rejected, it moves follow audio away from the speech it belongs to, with no message.
- A follow clip that holds the whole cut range is cut after all: rejected, F70 says "never split".
- Name the selected tracks of each window range (the first fix of plan gate 3 item 1): rejected, I and O and a ruler drag select every track by default, so the main guide workflows would cut the music bed, the case that F70 exists for.
- Send a transcript-pane Cut and Delete to `cutWords`: rejected, `cutWords` makes no clipboard excerpt, its run rule gives other ranges than the pane selection, and it adds three refusals to the pane.
- Keep an empty lane in the Cut excerpt for each follow lane that follows, so the paste map by position stays: rejected, the empty lane makes the follow track a paste target, a paste target is named, so an Insert splits the bed and opens a gap in it.
- Reuse `.nothingToCut` for a ripple where no lane cuts: rejected, its text names words, and the window shows it as a bug.
- Reuse `.overlap` for the refusal: rejected, the window maps `.overlap` to the bug text, and one case with two meanings needs the caller to know the edit.
- A new gesture limit that stops the ripple trim drag at the exact overlap frame: rejected for this landing; the 0020 throw rule already stops the drag at the last event that passed, with no second copy of the follow rule in `DirigibleTimeline`.

## Open questions and risks

- When the session format spec of 0068 lands, it gets the `follow` attribute of 0003.
- Another run can take version 16 first. Then this record and its tests take the next number. `SessionVersionTests.eachSessionVersionIsDistinctAndTheNewestIsTheLargest` fails a merge that leaves two `*SessionVersion` constants on one number, because a reader that does not know `follow` skips it and the next save drops the flag.
