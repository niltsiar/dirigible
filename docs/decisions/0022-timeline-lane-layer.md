# 0022. Timeline lanes: one layer of IOSurfaces written in place, with buffer age

- Status: accepted
- Date: 2026-09-27
- Accepted: 2026-09-27, after plan gate 1 of the timeline-layer run. The gate added the rule that the renderer writes only inside its rect (also the selection band), a fixed capacity per slot shown through `contentsRect`, the label context clipped to the drawn rect, the process footprint in probe P3, the pointer private to `PixelRegion`, two counters in place of a write log, and one point-to-pixel mapping in `LaneWindow`.
- Amends: 0017 (the Drawing paragraph), 0020 (the Budget paragraph and the dirty-rect consequence).

## Context

Decision 0017 draws the lanes in `draw(_:)` of the document view. On macOS 15.7.9, AppKit gives `draw(_:)` a display-list context: Core Animation draws the lane image later, and keeps one image per drawn region. The timeline-scroll run fixed a use-after-free of the reused buffer with an owned buffer per image, a buffer pool, scroll marks that free the images out of view, and a union of partial draws with a limit. That fix made the full draw of the lanes in view 13.5 to 15.4 ms p95, against 11.6 to 13.3 ms before (budget 16 ms, 0020). Its spike wrote the pixels into two IOSurfaces that are the contents of one layer: a full draw of 8.5 to 9.8 ms p95, with the same pixels. Run design: `.scratchpads/runs/2026-09-27-timeline-layer/design.md`.

Probes on 2026-09-27 (MacBook Pro 2018, Intel i5-8259U, macOS 15.7.9, Swift 6.2.4, target macOS 14; `.scratchpads/runs/2026-09-27-timeline-layer/probe/output.txt`):

- P1. The surface that is the layer contents is always `isInUse`. After a swap, the surface shown before stays in use for up to one display frame (p95 16.4 ms, none at 17 ms). A copy of a whole 2880 x 1200 px surface into another, shifted, with the swap and the flush, takes 2.4 ms p95. A swap and a flush with no pixel work take 0.26 ms p95. A lock does not wait.
- P2. An untagged surface shows other colors (R 196 against 200). A surface tagged `kIOSurfaceColorSpace` sRGB shows the colors of the draw path. `cacheDisplay(in:to:)` shows the sublayer contents. Every API compiles at the macOS 14 target.

## Decision

**Layer.** The document view has no `draw(_:)`. It sets `wantsUpdateLayer` and is not compatible with responsive scrolling. One `CALayer`, a sublayer of the document layer under the playhead, covers the lanes in view: the view columns, snapped to device pixels, and the rows of the whole lanes that the view crosses. Its contents is an IOSurface, and `contentsRect` shows the used part of it, so the contents never scale. `LaneWindow` owns the one mapping from points to pixel columns and pixel rows. `updateLayer()` runs in the display pass, so a scroll, the new frame of the layer, and its new contents commit in one transaction. The layer is in document coordinates: a late update shows the old pixels at their right place.

**Surfaces.** `LaneSurfaces` owns 4 slots, BGRA, tagged sRGB, with rows of an odd count of 64-byte lines. Each slot has one fixed capacity for a view size, scale, and lane height: ceil(view width x scale) + 1 columns, and (the lanes that fit in the view height + 1) x the lane rows. A scroll by a fraction of a point or across a lane edge keeps the capacity, so it makes no new surface. The memory bound is 4 x the capacity bytes (about 65 MB at 1440 x 600 pt, 100 pt lanes, scale 2). With 3 slots, full draws back to back found the picked slot in use at 42 of 120 draws (p95 16.1 ms, a new surface each); with 4, at none (p95 11.3 ms). Only `LaneSurfaces.show` writes a surface; the test accessor `frontRow` locks the front read-only. It writes only a slot that is not the contents and not `isInUse` at the pick. It lends the pixels as a noncopyable `PixelRegion` into a closure, then unlocks and sets the contents. `PixelRegion` keeps its pointer private and does every pixel write (spans, fills, the selection band). The guarantee: the pointer does not escape the region, and the region does not escape the closure. The `CGContext` that `withContext` gives for the labels must not escape its closure; this is a rule, not a type. When the picked slot is in use, it drops that surface and makes a new one; the window server keeps its own reference until its next composite. So the lanes hold 4 surfaces or fewer, never as wide as the session, and the main actor never waits for the compositor.

**Partial update in place (buffer age).** The picked slot is the oldest, so its commit is 4 commits old at most, and `LaneSurfaces` keeps the drawn rect of the last 3 commits. When the slot shows the same pixels as the new window, it gets from the front a copy of only the rects that the later commits drew, in the overlap of the front and the new window. A pixel changes only in a drawn rect, so the other pixels of the slot are current. Else it gets a copy of the overlap of the front, shifted by whole pixels (a scroll, a page turn, a new size). Then the renderer writes the changed rect (`changedColumns` of 0020, with its 360 pt row rule) and the new columns. A drag event copies at most three narrow rects; a 20 pt scroll copies the view once (about 2.1 ms) and renders 40 columns.

**Renderer.** `LaneRenderer.draw(_:into:at:)` writes every pixel of a rect of a caller's `PixelRegion`, and no pixel outside it: each clamp (clip boxes, waveform columns, lines, the selection band) is to the rect. So the selection band never halves a copied pixel twice. It rounds in absolute document pixels, so two partial draws agree with one full draw on each pixel, also at a fractional scroll origin. It keeps no pixel state: no buffer, no pool, and no image. The labels draw through a `CGContext` over the same region, clipped to the rect.

**Removed.** The owned buffer per image, the `CGDataProvider` release, the buffer pool, the scroll marks, and the union of partial draws with its limit. Each guarantee has a new owner: no write to pixels on screen (`isInUse` and the front check at the pick), bounded memory (4 slots), no image per region (one contents).

**Budget (amends 0020).** The 0020 budget is unchanged: each drag event and the full draw of the lanes in view at 2880 x 1200 px take 16 ms p95 or less, optimized, one event per 60 Hz frame; the renderer 8 ms p95 or less. The acceptance of this change: no case of `MouseEventBenchmark`, `FollowScrollBenchmark`, or `LaneRenderBenchmark` is more than 10% or 1 ms (the larger) worse than the main of the same session, in two alternate pairs, and the full draw is at most 80% of main.

**CLI (0011).** No command: the change is inside the drawing of the app target and operates on no package or audio file.

## Consequences

- 0017 gets an amended line: the lanes are one layer of IOSurfaces written in place (0022); the owned images, the scroll marks, and the union of partial draws are gone.
- 0020 gets an amended line: a drag event renders only its changed rect, with no union of the draws before it; the acceptance of 0022 compares every benchmark case with main.
- Memory: 4 surfaces of one capacity, about 65 MB at 1440 x 600 pt with 100 pt lanes at scale 2, and for up to one frame the surfaces that the window server still holds.
- A window resize makes new surfaces and renders in full at each step.
- Label antialiasing comes from a bitmap context and can differ from the AppKit backing in gray levels.
- Invariant: only `LaneSurfaces.show` writes a surface. The test accessor `frontRow` only reads the front. A second writer would bypass the `isInUse` check.
- Manual checks: a real unlocked screen with a trackpad, Retina and non-Retina displays, macOS 14, a 120 Hz display, Apple Silicon.

## Alternatives considered

- **Two surfaces and a full copy from the front at each update.** Rejected: the 1.5 ms trim case goes to about 2.9 ms, over the 1 ms tolerance.
- **Wait on `isInUse` for a free surface.** Rejected: the main actor blocks for up to 16 ms (P1), and the full draw gets worse than main.
- **A ring of column tiles in document coordinates.** No copy at a scroll. Rejected: 6 surfaces, a front and a back per tile that is still in use after a swap (P1), and a tile render per edit.
- **One wide surface addressed by x modulo its width, through `contentsRect`.** Rejected: wraparound in the renderer and the copy, and a split at the seam.
- **`CAMetalLayer` drawables.** Rejected: the system owns the drawable pool and its waits, and CPU pixels need one more copy.
- **Keep `draw(_:)` with an IOSurface-backed image.** Rejected: the display list still keeps an image per region.
