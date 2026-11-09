# 0038. Clip selection: one Selection enum with a range or a clip set, Command-click on a clip, and a group move with one nudge

- Status: accepted
- Date: 2026-10-04
- Accepted: 2026-10-04, after plan gate 1 of run `2026-10-04-multi-clip-selection`. The gate added the live IDs of every Core call on a clip set, Command-F on a set through `Marks.faded` per run, and the lane-only nudge guard.
- Amends: 0017 (Command-click on the upper part of a clip), 0018 (a second selection kind; the nudge of a clip set), 0020 (Command at the mouse-down on a clip; the group move and its commit).
- Amended: 2026-10-05, run `2026-10-05-clip-set-clipboard`. Copy and Cut act on a clip set through `Session.excerpt(of:)`: whole clips with their time and track offsets. A set paste clears only the frames under each pasted clip. Cut of a set is no ripple. After Paste or Insert of a set excerpt, the selection is the pasted clips. The lane menu shows Cut and Copy on a set. CLI: `dirigible clip paste-clips`.
- Amended: 2026-10-25, run `2026-10-16-timeline-clarity` (F155). A plain click on a clip, the commit of a move, trim, gain, fade, crossfade, or envelope point edit, and a right-click on a clip select the clip as a set of one clip. A ruler drag leaves the clip kind. The one public hull is `Selection.span`, for Zoom to Selection and the duck scope (0060). A Shift-drag on the ruler from a clip set extends the span of the set, and a Shift-click goes from the playhead to the click. Heal Clips and Place at Playhead are off for a clip set.
- Amended: 2026-10-27, run `2026-10-27-empty-drop-lane-click` (F109, see 0017). A plain click in a gap, on the lower part of a clip, or on a clip box under 12 pt replaces a clip set with the track of the click, as a range with no points. Paste and Insert of a set excerpt then go through `Marks.pasteTracks`: the first lane of the excerpt lands on the clicked track at the playhead, and the other lanes on the tracks under it. When the tracks under it are too few, the paste refuses with the `trackCount` alert and the session stays. The upper part of a clip of 12 pt or more keeps the clip as a set of one clip.
- Amended: 2026-10-29, run `2026-10-29-marquee-select` (F127). A Shift-drag on the lanes with no Command draws a marquee: at each drag event, the clips that it holds whole in time, on the lanes that it touches, become the clip set; no clip gives no selection; Esc gives the selection at the down. It replaces the Shift-drag range extension of the lanes: a Shift-drag on the lanes no longer extends the span of a clip set; a Shift-drag on the ruler and a Shift-Command drag on the lanes still do.
- Amended: 2026-11-06, run `2026-10-28-timeline-edits` (L2, F69). The table row "Any, Shift-Command" splits: a trim zone rolls a join or trims a loose edge, and the upper part of a clip slips it (see 0020); the lower part and a gap keep the range drag.
- Amended: 2026-11-09, run `2026-10-28-timeline-edits` (L4, F80, see 0020). A group drag uses the overlap mode of the drag mode, and Shuffle mode overwrites.

## Context

The triage of 2026-10-04 (A5, B2.6) asks for a selection of several clips, also on different tracks, with Command-click, and a drag that moves them together in time and across tracks. Hindenburg PRO selects several regions with Cmd-click "for editing. Cut, Copy & Paste or move the regions around" (`docs/research/edit-commands.md` section 5). Final Cut Pro adds or removes a clip with Command-click and draws a yellow border. Logic Pro adds a region with Shift-click and shows "*" for a mixed value in the Region inspector (`docs/research/multi-clip-selection.md`).

The window selection was `Marks` (in, out, tracks): a time range. Fifteen sites read it as a range through `Marks.selection(in:)`. A clip set has no range. Its hull (the first start to the last end, on the tracks of the clips) holds clips that the user did not pick. A hull that reaches Copy, Delete, a ripple, or an export loses or copies audio that the user did not select.

## Decision

**Model.** The window selection is one enum in DirigibleTimeline:

```swift
public enum Selection: Hashable, Sendable {
    case range(Marks)      // .range(Marks()) is no selection
    case clips(ClipSet)    // never empty
}
```

- `Marks` stays the range payload with no change. `Selection.marks` is nil for a clip set, so a range edit cannot read a clip set as a range. The one public hull is `Selection.span`, for Zoom to Selection and the duck scope (0060). It loses and copies no audio.
- `selectedClips(in:)` is the one read of the clips: the set clips for a clip set, the clips that the range holds whole for a range (`Marks.heldClips(in:)`, the nudge rule of 0018).
- A stale ID drops at the read, as `Marks.selection(in:)` drops a removed track. An undo does not repair the set. Every Core call on a clip set takes its IDs from `selectedClips(in:)`, never from `ClipSet.ids`, because Core throws `.unknownClip` on a stale ID.
- The two kinds are never active together. I, O, Select All, a range drag, a ruler drag, Esc, and Deselect All leave the clip kind.

**Gesture rules (amends 0020).**

| Press | Click (under 3 pt) | Drag |
|---|---|---|
| Upper part of a clip, no modifier, clip in `selectedClips`, 2 or more clips | That clip alone, as a set of one clip, no seek | Group move |
| Upper part of a clip, no modifier, other cases | That clip alone, as a set of one clip | Single move (`Session.move`) |
| Upper part of a clip, Command | `toggling(clip)`; the start set is `selectedClips` | Range drag |
| Lower part or gap, Command | Range: the track toggle of 0017. Clip set: no change | Range drag |
| Any, Shift, no Command | The Shift rules of 0017 | Marquee: the clips that it holds whole in time on the lanes that it touches, as a clip set; no clip gives no selection |
| Trim zone, Shift-Command | The Shift rules of 0017 | Roll of the join, or the plain trim of a loose edge, with no snap |
| Upper part of a clip, Shift-Command | The Shift rules of 0017 | Slip of that clip |
| Lower part or gap, Shift-Command | The Shift rules of 0017 | Range drag; it extends the range at the down, or the span of a clip set |
| Time area of the ruler | Seek at the down | Range drag; the playhead is no snap target |
| Trim, gain, or fade zone of a set clip | The rules of today | That clip only |

- A Command-click on the last clip of the set gives no selection. During a take (`canEdit` false), a Command-click changes the selection and no drag edits.
- A group move has one frame offset and one lane delta for all clips. The gesture clamps the offset (no start under 0, no end past `Frames.limit`) and the lane delta (every clip keeps a track). If one target track has the other layout, the lane delta is 0 and the group still moves in time (the single-move rule of 0020).
- A moved clip overwrites the unselected clips under it, as a single drop does. Moved clips never cut each other.
- The commit is one `nudge(_:by:lanes:)` on the session of the mouse-down, so one undo entry. After it, the selection is `.clips` of the moved clips, for both start kinds: a shifted range is not safe, because a gap of the source range can land on unmoved clips.
- Esc or a session change during a group drag drops it and keeps the selection.

**Edits on a clip set (amends 0018).**

| Command | Clip set |
|---|---|
| Delete | `removeClips` of the set; the gaps stay; the selection is empty |
| Copy | `Session.excerpt(of:)` of the live set clips, kind `.clips`; no change to the session |
| Cut | One edit: the set excerpt and `removeClips`; the gaps stay; the playhead stays; the selection is empty. No ripple, so a pending or split take does not block it |
| Heal Clips | Off: a clip set has no range |
| Delete and Close Gap, the two "in Selected Tracks" items | Beep (a ripple needs a range scope, 0037) |
| Paste, Insert | The first track (session order) with a set clip, at the playhead. After a set excerpt, the selection is the pasted clips |
| Split | The playhead, only on the tracks where a set clip holds it |
| Nudge | `nudge` of the set clips; the start stops at 0; the set stays |
| Command-F | `Marks.faded` for each per-track run of joined set clips, chained into one Session |
| Auto Level, the inspector (Mixed), Show Clips in Finder | The set clips |
| Remove Track, Export Selection, Place at Playhead | Nothing: a clip pick is not a track pick, and a hull exports clips that the user did not pick |
| Zoom to Selection | The span of the set (a view, not an edit) |
| Duck Music Under Speech | The hull of the set (`Selection.span`), on the time axis only (0060) |
| Lane menu | A right-click on a set clip keeps the set. Cut and Copy show and are enabled; Cut shows also under a pending or split take |

**Core.** `Session.nudge(_:by:lanes:)` moves N clips by a frame offset and a lane offset. Pass 1 reads and checks: a target track past the last track throws the new `SessionError.laneOutOfRange`, a target of the other layout throws `.layoutMismatch`, and a frame out of range throws `.frameOutOfRange`. Pass 2, on a copy, takes every moving clip out of every lane, then clears and inserts on each target lane. Only an offset of 0 with a lane offset of 0 changes nothing. `ClipLane` repairs a broken crossfade join (0036), so two joined clips that move together keep their crossfade. `Session.removeClips(_:)` removes clips and leaves gaps; an unknown ID throws. A throw changes nothing.

**CLI (0011).** `dirigible clip nudge <package> <clip>... --by N --lanes L` (`--lanes` 0 is the default), `dirigible clip remove <package> <clip>...`, and `dirigible clip paste-clips <package> <clip>... --at N [--onto T]...` (one `--onto` for each track from the first to the last clip; the default is the source tracks). Cut of a set has no command: it is `paste-clips` and `clip remove`.

**Look.** A selected clip box draws a light tint and a 2 pt outline in the system accent color, by clip ID, so the look follows the clips during a drag. A clip set draws no band and nothing on the ruler.

**Redraw (0020 invariant).** `changedFrames(from: Selection, to:, in:)` gives empty frames for equal values first. Range and range uses the Marks function. Clips and clips gives the boxes of the clips in the symmetric difference. A mixed pair gives the Marks frames of the range side and the boxes of the set.

**Budget.** One group drag event takes 16 ms p95 or less in an optimized build at 2880 x 1200 px, one event per 60 Hz frame, on the 2 h fixture (6 tracks, 2,000 clips per track): `make bench FILTER=MouseEventGroupBenchmark`. The paths: 2 clips on 2 lanes in time, the same 2 clips one lane down, 6 clips (one per lane) in time, and 2 clips 1 h apart, each at fit zoom and at the zoom of 60 pt boxes. A drag after Select All (12,000 clips) is outside the budget.

## Consequences

- A Command-click on the upper part of a clip no longer toggles its track (0017). The lower part and a gap keep the track toggle.
- Two Core edits serve the drags: `move` for one clip, `nudge` for a group. The single move, its IDs, and its bench do not change.
- A drag inside a range moves every clip that the range holds whole when the range holds the pressed clip whole and holds 2 or more clips. After Select All, a drag moves every clip.
- Three test-support shims (`Timeline.marks`, `GestureEffect.marks(_:)`, `ClipInspection(marks:session:)`) keep the range tests as they were. Sources has one path.
- Copy and Cut of a clip set use `Session.excerpt(of:)`, a second excerpt shape with the kind `.clips` (run `2026-10-05-clip-set-clipboard`).

## Alternatives considered

- **A clip set field on `Marks` with a `didSet` invariant.** The smallest diff. Rejected: the invariant is a runtime rule on three setters, `tracks` can go stale, and the compiler does not make a new consumer handle the clip kind.
- **Two window fields (`marks` and `clips`).** No churn. Rejected: both can be set at once, and each consumer must check the clips first.
- **A Core `Selection` with a selection-aware edit engine.** Rejected in 0018: the selection is window state, and the CLI would have to build a selection.
- **Every drag as a group of one.** Rejected: it changes the IDs and the bench of the single move.
- **A new `move` overload for the group.** Rejected: `ParityTests` matches names only, so it passes with no command.
