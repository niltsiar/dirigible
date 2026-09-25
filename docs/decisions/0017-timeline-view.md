# 0017. Timeline view: an AppKit document view with own pixels, peaks in the user cache

- Status: accepted
- Date: 2026-09-25
- Accepted: 2026-09-25, after plan gates 1 and 2 of the timeline-view run. The gates added the settle order with the `settling` flag, the pass that Studio starts after a pool change, the media open through `openMedia` with its stamp, the redraw only on a change of the drawn inputs, the narrowed record-over warning, and the read-only `dirigible peaks` command.

## Context

Release 1 run 4b (`docs/requirements/releases.md`) adds the track lanes with clips and waveforms, the playhead line, the markers ruler, zoom, a scroll that follows the playhead, and the selection that run 4c uses. A 2 h, 6-track session must draw at 60 fps while it plays. The main actor never reads a WAV, and a take never waits for peaks. Hindenburg research: `docs/research/timeline-view.md`.

Probes on 2026-09-25 (MacBook Pro 2018, Intel i5-8259U, Iris Plus 655, macOS 15.7.9, Swift 6.2.4; `.scratchpads/runs/2026-09-25-timeline-view/probe/output.txt`):

- P1. A 2 h mono 24-bit WAV (1.04 GB) gives peaks of 256-frame bins in 0.39 s with a warm cache. A cold SSD read of the file takes 0.35 s. The read block must be a multiple of the bin.
- F1 to F6. On APFS, the size and the mtime in ns change at a same-length rewrite. A copy (`ditto`, `FileManager.copyItem`) and a move keep them. A copy changes the inode. On exFAT, the mtime step is 10 ms, and a same-length rewrite within 10 ms keeps the stamp.
- D1 to D6. At 2880 x 1200 px with 6 lanes: Core Graphics fills of waveform columns take 160 to 1221 ms per full draw. Own pixels into a reused buffer take 4.0 to 5.3 ms p95. A full redraw at each frame gives 20 fps (AppKit) and 30 fps (SwiftUI Canvas). A scroll view whose document view is as wide as the session and draws only its dirty rect, with a `CALayer` playhead, gives 60 fps with page follow and with continuous follow, also at 10.8 million pt wide.

## Decision

**Drawing.** The lanes are an `NSScrollView` in the SwiftUI window. Its document view is flipped and layer-backed, as wide as the session at the zoom, and draws only its dirty rect. It writes BGRA pixels into a reused buffer (a background pattern, then column spans for the peak and the RMS), then draws one image. The playhead is a `CALayer` that the `NSView.displayLink` tick moves; the tick reads the playhead outside SwiftUI. The ruler is an `NSRulerView`. The track headers stay SwiftUI and share the lane height. The document view and the ruler each keep an `Equatable` value of their drawn inputs (the session, the peaks, the missing media, the selection, the zoom, the lane height). They redraw only when that value changes or the backing scale changes. The playhead is not a drawn input. `Studio.missingMedia` is a stored property of its own, not a field of the playback state, so the 33 ms playhead poll does not update the view.

**Waveform.** Rectified, -60 dB to 0 dB, light peaks over dark RMS, with clip gain plus track gain. A stereo track draws the maximum of both channels. A missing or short clip draws red. The red comes only from `Studio.missingMedia`.

**Peaks.** Three levels of 256, 4096, and 65536 frames per bin, a UInt16 peak and a UInt16 RMS per bin. `Studio` computes them off the main actor, one file at a time, and pauses before each block of 262,144 frames while a take starts, records, or finalizes. After a pause, the file starts again with a new `stat`. The pass opens each WAV with `openMedia`, as the Player and the media check do, and merges its faults into `missingMedia`. `openMedia` also gives the stamp of the descriptor that it opened. A read error gives `.unreadable` in `missingMedia`. Studio starts a pass at the open, after a finalize, and after an edit, an undo, or a redo that changes the pool files. The window starts one at focus, because a WAV can change outside the app. The views read only `Studio.peaks`.

**Close.** `settle()` first sets a flag: from then, a request for a pass does nothing, and a running pass stops at its next file, its next block, or its next 100 ms wait. `settle()` ends the take, then cancels the pass and waits for it, then clears the flag. The last two steps run on every exit of `settle()`. So settle always ends a take within a bound, and no task holds the package lock after a close. A cancelled close or a cancelled Quit asks for a pass again.

**Cache.** One file per pool WAV in `~/Library/Caches/com.delineas.dirigible/Peaks/`, named by the pool path, the size, and the mtime of the WAV. The format is version 1 of the table in the run design: a 64-byte little-endian header with the magic `DIRPEAKS`, then the bins. The reader refuses a file whose fields do not match the WAV, and a refusal is a miss. A write error keeps the peaks in memory. The package does not change, so 0003 does not change.

**Selection and view state.** The in point, the out point, and the selected tracks, the zoom, and Automatic Scroll are window state. None is saved. The selection has one read: a range and at least one track that exists now, or nothing.

**Record-over warning.** The transport bar warns only when an armed track has a clip at the playhead that is not in view: its lane is under the visible lanes, or the playhead is outside the visible frames. Before the first layout, nothing counts as in view. A window minimum height for all lanes was rejected, because the brief sets no track limit.

**Follow.** Automatic Scroll turns pages as in Hindenburg: at 94% of the width the view moves so the playhead is at 11%. A user scroll during play holds the follow until the playhead is in view again, a seek, or a play start.

**Keys.** View: Zoom In (Command-plus), Zoom Out (Command-minus), Zoom to Session (Command-0), Zoom to Selection (H), Automatic Scroll (Option-Command-F). Edit: Set In Point (I), Set Out Point (O), Deselect All (Shift-Command-A), Select All (the system item). Esc empties the selection through `cancelOperation(_:)`; it has no menu item, because a menu item would take Esc from alerts and sheets.

**CLI (0011).** The peak compute reads the audio files of a package, so the 0011 clause for a feature that operates on an audio file applies. `dirigible peaks <package>` reads the cache and writes nothing: for each pool file, `hit` with the bin count, `miss`, or `missing`. It reads the cache only through the public function `peakCacheStates(of:package:cache:)`. It takes no lock and starts no compute. The app and the CLI use one definition of the cache folder.

## Consequences

- 0002 gets an amended line: `DirigibleApp/Timeline/` holds the timeline view, and `Studio+Peaks.swift` loads the peaks.
- 0016 gets an amended line: the record-over warning of the transport bar shows only for a clip that is not in view, because the lanes draw the clips.
- 0011 gets an amended line: `dirigible peaks` reads the peak cache.
- A package on another Mac, or after a cache purge, computes its peaks again: under 1 s per 2 h track on an SSD, about 10 s on a USB hard disk (inference).
- Closer than 256 frames per pixel, the waveform is blocky. The zoom stops at 128 frames per point.
- An exFAT rewrite of a WAV with the same length within 10 ms keeps a stale cache hit. No in-app path rewrites a WAV that fast.
- Orphan cache files stay after a WAV rewrite until the system purges Caches.
- The pass does not pause during play. A manual check on a USB hard disk decides it; if play drops out, the pass also pauses during play.

## Alternatives considered

- **`Peaks/` in the package.** The peaks move to another Mac with the package. Rejected: a lock-holder write path, a read-only-package case, and a 0003 change, for data that computes in under 1 s per 2 h track.
- **Remove the record-over warning.** Rejected: a lane under the visible lanes, or a playhead off screen, hides a clip on an armed track.
- **Peaks in memory only.** Rejected: a reopen of a 6-track 2 h session on a slow disk computes for about 60 s each time.
- **SwiftUI `Canvas`, or a full redraw at each frame.** Rejected: 30 fps and 20 fps (D3, D4).
- **Core Graphics path or rect fills.** Rejected: 160 to 1221 ms per full draw (D1).
- **A centered, fixed playhead.** Rejected for now: Hindenburg PRO 2 turns pages. The probe shows that it would also reach 60 fps.
- **An Esc menu item.** Rejected: it takes the key from alerts and sheets.
