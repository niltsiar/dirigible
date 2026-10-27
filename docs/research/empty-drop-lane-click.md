# Research: a drop on an empty session, and a click in an empty lane

Date: 2026-10-27

Questions: (1) What does a drop of audio files do on a session with no tracks (F108)? (2) What does a click in an empty part of a track lane select, and where does Paste go after it (F109)? The marks are P (primary: vendor manual or vendor video frames), S (secondary), and U (unconfirmed: no source found). Decisions: 0040 (the drop), 0017 and 0038 (the click).

## 1. A drop on an empty session (F108)

- **Hindenburg.** "Drag any Audio file from Finder to Hindenburg" [HJ p. 15] (P). No source says what a drop does on a session with no tracks, how it names the tracks, or in what order it adds them (U). The 13c search of all 100 pages of [HJ] found no multi-file rule (`docs/research/file-import.md` sections 1, 2, 7).
- **Logic Pro 9.** A drag of several files opens a dialog. "Create new tracks: Creates new tracks (and audio channel strips) for each dragged file." "Use existing tracks: Sequentially places the dragged files (as regions) onto existing tracks, starting with the currently selected track." "Place all files on one track: All files are placed sequentially (one after the other) on the track they are dragged to." "Copy audio file names to track names: Uses the filenames to rename tracks." [L9D] (P, old manual).
- **Logic Pro, current.** A drop "to the area below all existing tracks" adds a new track; several files open "Add Files to Tracks" with new tracks, existing tracks, or one track [LDD] (P, from `file-import.md`; the page did not render for this run, so the quote is not checked again). No source gives the order of the new tracks (U). Inference: the order of the dragged files.
- **GarageBand.** "Drag the audio file ... to an audio track or to the empty area below the existing tracks" [GBI] (P). No source for an empty project or several files (U).
- **Final Cut Pro.** A clip connects "at the point where you released the mouse" [FCC] (P). No track model; no rule for an empty timeline (U).
- **HIG.** Highlight a destination only when it can accept the item; show no cue for an item that it cannot accept [HIG] (P).
- **Dirigible.** A session with no tracks shows a `ContentUnavailableView` with Add Track and Add Call Tracks, and no lanes. Only `TimelineScrollView` takes a file drag on the lanes. The empty state holds real `NSButton` views (`Tests/DirigibleTests/EmptyStateTests.swift`). Inference: a drop host must be a superview of these buttons or the window; a sibling view gets no drag over a button.

## 2. A click in an empty lane (F109)

- **Hindenburg, click in a lane.** "The frames of [V-inout] show a click with the I-beam in a track lane. After the click, the playhead line is at the click point. No selection band shows." (`docs/research/timeline-view.md` section 2) (P, video frames). The frames do not show if the name bar of that track turns blue (U).
- **Hindenburg, click on a region.** "The track of the clicked region becomes the selected track. Its name bar turns blue." [V-selregion] [V-movetrack] (`docs/research/edit-commands.md` section 1) (P, video frames).
- **Hindenburg, Paste.** "The user clicks the track 'Interview' and moves the playhead. Cmd-V puts the audio on 'Interview' at the playhead." [V-paste] (`edit-commands.md` section 6) (P, video frames). The frames do not show if the click was on the header or in the lane (U).
- **Hindenburg, the selected track look.** "The name of a selected track in a blue bar. Its lane is a lighter blue-grey than the other lanes." [V-inout] [V-marker] (`timeline-view.md` section 2) (P).
- **Hindenburg, scope of a range.** "A dark, half-transparent band between the in and out lines on each selected track. A track that is not in the selection shows only the green and red lines." [V-esc] (`timeline-view.md` section 6) (P). Inference: the selected tracks scope the in and out points.
- **Hindenburg, clear.** "A Selection Can Also be Removed by Double Clicking in the Grey Area" [V-esc] (P).
- **Logic Pro 10.1, select a track.** "Click any empty part of the track header." "When you select a track, all regions on the track (or those that fall within the cycle, if Cycle mode is on) are selected." "To select a track without changing the current region selection, Option-click the track." "When multiple tracks are selected, the first selected track is the focused track." [LST] (P). The page has no rule for a click in the lane area (U).
- **Logic Pro, Paste.** "Select the track where you want to paste the region, move the playhead to the point where you want the region to start, then choose Edit > Paste" [LCP] (P, from `docs/research/clip-set-clipboard.md`).
- **Logic Pro, a click in the empty Tracks area.** A search summary says that a tap on an empty area of the Tracks area deselects the regions in Logic Pro for iPad (S, the page body did not render). No Mac source (U).
- **GarageBand.** A track header is "located to the left of the track" (S, search summary). No source for a click in the lane (U).
- **Final Cut Pro.** No tracks to select (the magnetic timeline has lanes of connected clips, not tracks). No source fetched for a click in an empty area (U).

## 3. Probe P1 and open questions

- **P1, question A: which host takes a Finder drag over the empty state?** `EmptyDropView`, an `NSView` that registers `.fileURL` and hosts the SwiftUI content in an `NSHostingView` subview, takes the drag over the Add Track button. A real Finder drag (`scripts/hid.swift drag --outside`) onto the button made track "a" at frame 0 on the verify copy. The probe was the real host: no throwaway patch was built, and the window candidate (`UndoRoutingWindow`) and SwiftUI `dropDestination` were not tried.
- **P1, question B: in what order does the Finder give the URLs of a drag of several files?** Not measured. The agent could not sort or select files in Finder: `osascript` had no assistive access, and `scripts/hid.swift` clicks no Finder item. The code keeps the order of the drag pasteboard (`AppDelegate.audioFiles(on:)`). Check M1 (three files in a Finder list view sorted by Date Modified that shows c, a, b, with all three selected by Command-A) tells the pasteboard order from the name order.
- **Q3 (open).** After a click in an empty lane in Hindenburg PRO, does the name bar of that track turn blue? A hardware check in Hindenburg; no source.

## Sources

- [HJ] Hindenburg Journalist PRO 1.21 user guide: https://www.willyurman.com/teaching/handouts/Hindenburg_Journalist.pdf (P)
- [V-inout], [V-selregion], [V-movetrack], [V-paste], [V-esc], [V-marker]: the Hindenburg video frames of `docs/research/timeline-view.md` and `docs/research/edit-commands.md` (their `## Sources` list the URLs) (P)
- [L9D] Logic Pro 9.1.6 user manual, chapter 11 section 4: https://help.apple.com/logicpro/mac/9.1.6/en/logicpro/usermanual/chapter_11_section_4.html (P, read 2026-10-27)
- [LDD] Logic Pro, Create tracks using drag and drop: https://support.apple.com/guide/logicpro/create-tracks-using-drag-and-drop-lgcpd1e675e5/mac (P, from `file-import.md`)
- [LST] Logic Pro 10.1, Select tracks: https://help.apple.com/logicpro/mac/10.1/en.lproj/lgcp66ed91bd.html (P, read 2026-10-27)
- [LCP] Logic Pro, Copy and paste regions: see `docs/research/clip-set-clipboard.md` `## Sources` (P)
- [GBI] GarageBand, Import audio and MIDI files: https://support.apple.com/guide/garageband/import-audio-and-midi-files-gbndd01649ed/mac (P)
- [FCC] Final Cut Pro, connect clips: https://support.apple.com/guide/final-cut-pro/ver7a77ef9e/mac (P)
- [HIG] Human Interface Guidelines, Drag and drop: https://developer.apple.com/design/human-interface-guidelines/drag-and-drop (P)
