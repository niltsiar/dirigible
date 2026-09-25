# 0020. Mouse edits: a DirigibleTimeline library with one pure gesture model, a preview outside SwiftUI state, and a commit that carries its base

- Status: accepted
- Date: 2026-09-26
- Accepted: 2026-09-26, after plan gates 1 and 2 of the mouse-edits run. The gates added the 12 pt floor of the move zone, the lane change after half a lane, the name commit at the mouse-down, the order apply, source, draw at the mouse-up, the one geometry for the drawing and the hit test, and the Studio read only at the down and after the up.

## Context

Release 1 run 4d (`docs/requirements/releases.md`) adds the mouse edits on the lanes and the ruler: a click that selects a clip, a drag that moves it (also to a lane of the same layout), an edge drag that trims it, Shift-drag, the drag of a marker flag and of the in and out triangles, the ruler menu, and the cursors (F13). It adds no Core edit and no `dirigible` command (0018). Hindenburg research: `docs/research/mouse-edits.md`. The run design: `.scratchpads/runs/2026-09-26-mouse-edits/design.md`.

Constraints:

- `TimelineScrollView.update(_:)` sets the lane inputs at each SwiftUI update (peaks, the media check, the Marks). A preview in those inputs is lost in the middle of a drag.
- `SessionWindow.edit` shows an alert on each throw. A `move` replayed after an undo throws `.unknownClip`.
- `Marks` and `TimelineScale` are pure, but they are in the executable target `DirigibleApp`. AGENTS.md asks for a thin app target and logic in library targets.
- At 2 h, 6 tracks, and 2,000 clips per track, a `move` on a copy takes 3.6 ms p95 and a lane draw of 2880 x 1200 px 4.6 ms p95 (optimized, 0018 probe P4, 0017).

Probes on 2026-09-26 (MacBook Pro 2018, Intel i5-8259U, macOS 15.7.9, Swift 6.2.4; `.scratchpads/runs/2026-09-26-mouse-edits/probe/`):

- C1. `NSCursor` arrow, iBeam, openHand, closedHand, pointingHand, and resizeLeftRight compile with `-warnings-as-errors` at the macOS 14 target. `columnResize` is macOS 15 and later.
- L1. The clip labels at fit zoom (12,000 clips in 1440 pt) take 330 ms p95 per draw. With no label in a box under 30 pt, 0 ms. 216 labels take 5.7 ms p95.

## Decision

**Module.** A new library target `DirigibleTimeline` depends on `DirigibleCore` and imports Foundation only. It holds `Marks` and `TimelineScale` (moved from `DirigibleApp`), the lane and ruler geometry, `trimLimits`, the cursor kinds, and `TimelineGesture`. `DirigibleApp` depends on it. The views forward mouse events and map cursor kinds to `NSCursor`. `LaneGeometry` and `RulerGeometry` are the one geometry: the views and `LaneRenderer` draw with them and the hit test reads them, so the drawn box is the hit box. `trimLimits` and the hit types are internal; their tests use `@testable import DirigibleTimeline`. `ClipLane.index(holding:)` becomes public; it is a binary search and changes nothing.

**One gesture model.** `TimelineGesture` is a value type with one state enum (idle, pressed, moving, trimming, ranging, markerDrag, pointDrag, dropped). `handle(_:_:)` takes a typed event (down, drag, up, escape, sessionChanged) and a context (the session, the Marks, the playhead, the geometry, `canEdit`), and returns typed effects (Marks, seek, current marker, commit). A point has a tagged space (`Place.lanes`, `Place.ruler`); only `LaneGeometry` converts points to frames. No public API returns a lane index.

**Preview.** The scroll view owns the gesture and keeps the last SwiftUI inputs as its source. It draws the preview over the source at each update, so a SwiftUI update does not remove it. The preview never enters observable window state. At a mouse-down, the window commits the typed track names first, and the source takes the Studio session, so a rename just before a drag does not drop the drag. A drag event does not read the Studio session: a change during the drag reaches the gesture through the next SwiftUI update, which drops it. At the mouse-up, the window applies the effects first, then the source takes the Studio session, then the view draws, so the lanes never draw the old session. A preview edit that throws keeps the last preview; no gesture input reaches that case.

**Commit.** At the mouse-up, the gesture returns a `GestureCommit` with the session of the mouse-down (`base`) and the result of one Core edit on it (`move`, `trim`, or `setMarker`). `apply(to:)` sets the session to the result only when the session is still `base`. It never throws. So an undo, a redo, or another edit during a drag drops the gesture with no alert and no undo entry, and a take drops it through the 0018 idle gate. A drag is one undo entry.

**Rules.** The zones of a clip box: 4 pt inside each edge trims, the upper two thirds moves, the lower third and a gap make a range (0017). A box under 12 pt is all range, so a small drag at fit zoom cannot move a clip that the user cannot see. Shift or Command at the mouse-down makes a range press. A move goes to another lane after half a lane of vertical movement, when the layout of that lane matches, else it stays on its lane; it overwrites the clips under it (0003); its start is 0 or more. A trim stops at a neighbor, at the file, and at a length of 1 pt at the zoom (at least 1 frame). On the ruler, a triangle comes before a flag, and a flag before a seek. A flag takes x from its position - 3 pt to its position + 6 pt (the line and its box). A ruler mouse-down makes the lanes the first responder, so Esc reaches the gesture and not a focused text field. A triangle stops before the other point. The ruler menu adds a marker or a chapter at the clicked frame and deletes the flag under the pointer. Esc during a gesture cancels only the gesture. A clip label draws only in a box of 60 pt or more (L1).

**Budget.** One drag event (the gesture step, the preview edit, and the draw of the lanes in view with labels at 2880 x 1200 px) takes 16 ms p95 or less in an optimized build: `make bench FILTER=MouseEventBenchmark`.

**CLI (0011).** No command. The gesture changes window state and calls `move`, `trim`, `setMarker`, and `removeMarker`, which have `dirigible clip move`, `clip trim`, `marker set`, and `marker remove`.

## Consequences

- 0002 gets an amended line: `DirigibleTimeline` (library) holds the timeline selection and the gesture model; `DirigibleApp` depends on it.
- 0017 gets an amended line: a click on a clip body selects the clip and does not seek; a narrow clip has no label.
- `MarksTests` moves to `DirigibleTimelineTests`. Test files that use `Marks` import `DirigibleTimeline`.
- `ImportRuleTests` checks that `DirigibleTimeline` imports only Foundation and DirigibleCore.
- A drag redraws all lanes in view at each event. A dirty rect of the old and new clip boxes is the upgrade path.

## Alternatives considered

- **The gesture in the app target, the preview in the document view.** Rejected: the gesture tests need a window and a studio, and the app target grows.
- **The preview as observable window state.** Rejected: each drag event would update SwiftUI, and the drawn session would have two owners.
- **Replay the edit at the mouse-up and catch the throw.** Rejected: it covers only the listed errors; an edit that does not throw on a changed session would commit onto the wrong state.
- **One type per gesture behind a protocol.** Rejected: one conformer each (AGENTS.md).
