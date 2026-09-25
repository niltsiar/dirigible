# Timeline view in Hindenburg PRO 2

Date: 2026-09-25

This document records how the Hindenburg workspace shows the timeline: playhead follow, click targets, zoom, the ruler, markers, waveforms, and selections. It also records the Apple facts for a timeline view on macOS 14. It adds to `docs/research/timeline-playback.md` and does not repeat it. The source tags [HM], [HW], [HR], [Rnnnn], [KB-*], and [V-*] have the same meaning as in that document.

This document uses one more kind of evidence: still frames of the official videos. We downloaded the videos and looked at frames. A sentence that starts with "The frames of [V-x] show" reports what the frames show. Some of these videos show a window with the title "Hindenburg Journalist Pro" (version 1.x), although the PRO 2 function pages show them [V-autoscroll] [V-peaks]. Thus a frame shows the 1.x interface. PRO 2 can differ.

A claim that no primary source confirms has the mark "(unconfirmed)". A sentence that starts with "Inference:" is our reading of the sources.

## 1. Playhead follow

- **The command.** View > Automatic Scroll is a check item in the View menu [HM p. 100] [V-autoscroll]. The PRO 2 video says "Workspace will follow playhead" [V-autoscroll]. It has no key [V-autoscroll].
- **Off.** A caption in the video says: "Without Automatic Scroll Selected, the Playhead will Continue Moving While the Image is Fixed" [V-autoscroll].
- **On.** A caption says: "Now the Screen Scrolls With the Playhead" [V-autoscroll].
- **Page or continuous.** The frames of [V-autoscroll] show that the view stays fixed while the playhead moves to approximately 94% of the width. Then the view jumps, and the playhead shows again at approximately 11% of the width. Inference: Automatic Scroll turns pages. It does not keep the playhead fixed.
- **Fixed playhead.** A user asked for a fixed playhead in the center in 2019. On 2020-04-20 Hindenburg answered: "Fixed playhead is unfortunately not something we can do in the current version, but we are hoping we can implement it in the upcoming 2.0" [UV-freeze]. The PRO 2 release notes do not mention a fixed playhead [HR]. A fixed playhead in PRO 2 is unconfirmed.
- **Why users ask.** A 2019 user post says: "the playhead sweeps over the region to be cut out, so one must scroll back to get the relevant part in view" [UV-halfscreen]. Inference: after a page jump, the audio that just played is off screen.
- **Scroll during play.** No source says what happens when the user scrolls during play (unconfirmed).
- **Default and storage.** No source says if Automatic Scroll is on by default, or if the session file keeps it (unconfirmed). The frames of [V-peaks] show the item checked.
- **Narrator.** Hindenburg Narrator, a sister product, has a preference "Center playhead after zoom". Its video says: "Will set the playhead in the middle of the workspace after zooming in around the playhead" [N-center]. Narrator also has the preferences "Mouse wheel zooms around playhead" [N-wheel] and "Automatic track height" [N-trackh]. These pages have no text. Inference: the Narrator workspace and the PRO workspace share code. PRO 2 has these preferences (unconfirmed).

## 2. Click targets

- **The ruler.** The Windows guide calls the bar above the tracks the "Timeline". A right-click on it adds a marker [HW p. 26]. The frames of [V-marker] show that a right-click on the ruler opens a menu: Add Marker (Cmd-Return), Add Chapter (Shift-Cmd-Return), Add Cue Point (Option-Cmd-Return), Add RAD Marker, Add Cart Marker (submenu), and Delete Marker.
- **Left-click on the ruler.** No source says if a left-click on the ruler moves the playhead (unconfirmed).
- **Drag on the ruler.** A caption says: "You can reposition your In & Out markers by dragging them across the timeline" [V-drag]. The frames show the user drag the in and out triangles on the ruler. An "In" label shows during the drag [V-inout].
- **Click in a lane.** The frames of [V-inout] show a click with the I-beam in a track lane. After the click, the playhead line is at the click point. No selection band shows. Inference: a single click in a lane moves the playhead and does not make a selection.
- **Shift-click.** Shift-click makes "a selection from current playhead position to desired selection out position" [HW p. 14].
- **Click on a region.** A click selects the region, and "It turns orange" [HW p. 16] [V-region]. No source says if the click also moves the playhead or sets the in and out points (unconfirmed).
- **Double-click on the grey area.** A caption says: "A Selection Can Also be Removed by Double Clicking in the Grey Area" [V-esc].
- **Arrow keys.** A 1.21 preference, "Arrow control rew / fwd", toggles the Left and Right Arrow keys between "scroll" and "region jump" [HM p. 76] [HW p. 29].

## 3. Zoom

- **Keys in PRO 2.** Cmd-plus and Cmd with the mouse wheel zoom in [V-zoomin]. The Apple line of the zoom-out video says "Ctrl Minus or Ctrl Mousewheel" [V-zoomout]. Inference: this is a typing error for Cmd. The 1.21 manual gives Cmd-minus [HM].
- **Function keys in 1.21.** F5 zooms in, F4 zooms out, F3 zooms to the selection, F6 fits and centers, and Cmd-F6 fits the session [HM p. 95-96]. The Windows guide swaps F4 and F5 between page 17 and page 34 [HW].
- **Zoom to selection and fit in PRO 2.** No video text confirms H or the fit keys in PRO 2 (unconfirmed).
- **Anchor.** The frames of [V-zoomin] show the user click the toolbar "In" button. The playhead stays at the same screen position while the ruler scale changes. The frames show this for two zoom steps. Inference: toolbar zoom anchors on the playhead.
- **Mouse wheel anchor.** No source says if Cmd with the mouse wheel anchors on the pointer or on the playhead (unconfirmed). The Narrator preference "Mouse wheel zooms around playhead" suggests a choice between the two [N-wheel].
- **Limits.** No source gives the maximum zoom in (for example, to samples) or the maximum zoom out (unconfirmed).
- **Scroll keys in 1.21.** Up Arrow and Down Arrow scroll the tracks. Shift-minus and Shift-plus scroll left and right [HM p. 95]. In PRO 2, Up Arrow and Down Arrow move between tracks [V-tracks].
- **Trackpad.** Build 2558 "Reversed direction of two finger horizontal scroll on Windows" [R2558]. Build 2570 "Corrected simultaneous vertical and horizontal scrolling" [R2570]. Inference: a horizontal two-finger scroll pans the timeline.

## 4. Ruler and markers

- **Time format.** The frames show ruler labels in minutes and seconds, for example "00:00, 00:05, 00:10" [V-inout]. At a closer zoom, the labels show tenths, for example "00:05.2, 00:05.6" [V-autoscroll]. The label step changes with the zoom. No frame shows hours (unconfirmed for sessions longer than one hour).
- **Counter.** The frames show the counter as "01:40" with ".800" in smaller digits [V-marker].
- **Grid.** View > Grid > Enabled shows "a Grid on the Timeline" [V-grid]. View > Grid > Fine Grid helps to "Align regions to the timeline accurately" [V-finegrid]. The frames show the grid as vertical lines across all lanes [V-inout]. An old Windows build shows "The white area with the blue grid lines" [HW p. 5].
- **Markers.** The frames of [V-marker] show a new marker as a small orange flag on the ruler. The label "Marker 3" shows to the right of the flag. A thin orange line goes down across all tracks. The first new marker is number 3, because markers 1 and 2 are the in and out points [HM].
- **In and out points.** The frames show the in point as a green triangle on the ruler and a green line across all tracks. The out point is a red triangle and a red line [V-inout] [V-drag] [V-esc].
- **Chapters and cue points.** Cue point markers show "above a region" [R2604]. No source shows how a chapter looks on the timeline (unconfirmed).

## 5. Waveforms and regions

- **Waveform style.** The Windows guide says: "Rectified waveform display is a logarithmic display of the audio." It shows "Peaks", "Minimum Average", and "Maximum Average" [HW p. 28]. "The darker the waveform looks, the louder it will sound." Compressed music is dark blue. Speech without compression is light blue [HW p. 28].
- **No waveform.** Ctrl-W hides the waveforms on Windows 1.x [HW p. 28].
- **Peaks Only.** The frames of [V-peaks] do not show a clear difference at the video resolution. The look of "Peaks Only" is unconfirmed.
- **Colors.** The frames show every unselected region as a light blue box with a dark blue waveform, on all tracks [V-peaks] [V-inout]. A selected region is a tan box with a brown waveform. It has small square handles at the corners and at the top center [V-region] [V-peaks]. PRO 2 has a "Colours" feature: build 2572 fixed "non-functioning keys in Clipboards after using Colours" [R2572]. The feature page did not show text on 2026-09-25 [F-colours]. In 2020, Hindenburg wrote: "We do have plans for many more colours in Hindenburg 2.0" [UV-colors]. How the user sets a region or track color is unconfirmed.
- **Clip gain and stretch.** Build 2558 fixed the "waveform on merged regions with clip gain" and "with time stretch" [R2558]. Inference: the drawn waveform includes the region gain and the time stretch.
- **Fades.** The frames show a fade as a sloped side of the region box [V-zoomin].
- **Region name.** The frames show the name at the bottom-left corner of the region, in small white text. A narrow region shows a short name with "..." [V-inout] [V-region].
- **Track height.** Shift-Cmd-plus and Shift-Cmd-minus make the tracks larger and smaller in PRO 2 [V-trackup] [V-trackdown]. The frames of [V-peaks] show four tracks that share the window height. The limits are unconfirmed.
- **Selected track.** The frames show the name of a selected track in a blue bar. Its lane is a lighter blue-grey than the other lanes [V-inout] [V-marker].
- **Other drawing notes.** Build 2570 fixed a "redraw error when the playhead crosses a selection" [R2570]. Build 2606 fixed a "Transparent background when moving regions" [R2606]. Build 2600 fixed the "Background colour of cross fades in dark mode" [R2600]. Video thumbnails show on the timeline [R2630]. Build 2744 (Windows) "improved workspace rendering" [R2744].

## 6. Selection

- **Several tracks.** The frames of [V-esc] show a dark, half-transparent band between the in and out lines on each selected track. A track that is not in the selection shows only the green and red lines.
- **After Esc.** The frames show that the band goes away. Faint in and out lines stay on the tracks [V-esc]. The 1.21 manual calls them the "ghosted" in/out lines [HM p. 26].
- **Keys that are new in this document.** In 1.21, Shift-Option-Right Arrow and Shift-Option-Left Arrow add regions to the right and to the left [HM p. 95]. A preference, "Use Space for mark", makes Space set the in point and then the out point ("Smart In/Out") [HM p. 76, p. 95].
- **Storage.** No source says if the session file keeps the selection or the in and out points (unconfirmed). The session file keeps the playhead time [R2610].

## 7. Peak or waveform cache

- No primary source names a peak file or a waveform cache file (unconfirmed). The PRO 2 release notes use "waveform" only in the build 2558 fixes [R2558]. They do not use "peak file", "overview", or "cache" [HR].
- The knowledge base list has 107 articles. No article is about peak files or cache files [KB-all].
- The waveform help article says: "The light tops represent the peaks, while the dark middle represents the RMS value." It adds that the bottom half is omitted to give more space for detail [KB-wave].

## 8. Apple facts for a timeline view

SwiftUI:

- `Canvas` is "a view type that supports immediate mode drawing". The renderer closure gets a `GraphicsContext` and a `CGSize` (macOS 12) [A-CV].
- A canvas "doesn't offer interactivity or accessibility for individual elements". It "might provide better performance for a complex drawing that involves dynamic data" [A-CV].
- `rendersAsynchronously` tells if "the canvas can present its contents to its parent view asynchronously". The default is `false` [A-CVI]. With `opaque: true`, performance can improve, but a non-opaque image in the context gives undefined results [A-CVI].
- `TimelineView` "redraws the content it contains at scheduled points in time" [A-TV]. `.animation` is "a pausable schedule of dates updating at a frequency no more quickly than the provided interval". With `animation(minimumInterval:paused:)`, `nil` lets the system pick the interval, and `paused` stops the updates [A-TA].

Core Animation and AppKit drawing:

- A `CALayer` manages "image-based content". Layers often give the backing store for views [A-CL].
- A `CAShapeLayer` "draws a cubic Bezier spline". It draws with antialiasing. When possible, it maps the shape into screen space before it rasterizes. "Shape rasterization may favor speed over accuracy" [A-SL].
- For a layer-backed view, the default `layerContentsRedrawPolicy` is `duringViewResize`. This policy redraws the content continually during an animated resize [A-RP].
- `.onSetNeedsDisplay` redraws only after a `setNeedsDisplay` call, not after a size change [A-RPO]. `.never` never redraws the layer contents [A-RPN].
- `wantsUpdateLayer` is `false` by default, so the view uses `draw(_:)`. If it is `true`, the view calls `updateLayer()` instead. Apple recommends the `onSetNeedsDisplay` policy with `updateLayer()` [A-WUL] [A-UL].

Scrolling and magnification:

- `NSScrollView` coordinates `NSClipView` and `NSScroller` [A-SV]. `documentView` is "the view the scroll view scrolls within its content view" [A-DOC].
- `NSView.scroll(_:)` scrolls the closest ancestor `NSClipView` so that a point in the view lies at the origin of the clip view bounds [A-SCR].
- `allowsMagnification` is `false` by default. It "does not prevent the developer from manually adjusting the magnification value" [A-AM].
- `magnification` is 1.0 by default [A-MG]. `minMagnification` is 0.25 by default, and `maxMagnification` is 4.0 by default [A-MIN] [A-MAX].
- `setMagnification(_:centeredAt:)` keeps the given point "at the same screen location" after the scale change. `magnify(toFit:)` fits a rectangle. The result of both is clipped to the limits [A-SMC] [A-FIT].
- Inference: a 4x scroll view magnification cannot cover a range from the whole session to single samples, and it scales the drawn content. A timeline changes the width of the document view (points per second) and redraws.
- During responsive scrolling, AppKit calls `prepareContent(in:)` before it draws the overdraw region. `preparedContentRect` is the part of the view that AppKit rendered and cached [A-PREP] [A-PCR].

Display sync:

- `NSView.displayLink(target:selector:)` (macOS 14) returns a `CADisplayLink` "whose callback will be invoked in-sync with the display the view is on". If the view is hidden or on no display, the callback does not run [A-DL].
- `CADisplayLink` is available on macOS 14. The target reads `timestamp` and `targetTimestamp`. `preferredFramesPerSecond` sets the rate. `isPaused` stops the callbacks. Call `invalidate()` at the end [A-CADL].
- `CVDisplayLinkCreateWithActiveCGDisplays(_:)` is deprecated in macOS 15.0 [A-CVDL].

File events and caches:

- `DispatchSource.makeFileSystemObjectSource(fileDescriptor:eventMask:queue:)` watches "an open file or socket". The source starts inactive. Call `activate()` to start the events [A-FSO].
- The event flags are `write` (data written), `delete`, `rename`, `extend` (size change), `attrib` (metadata change), `link`, `revoke`, `funlock`, and `all` [A-FSE] [A-FSEW].
- `FileManager.SearchPathDirectory.cachesDirectory` is "Discardable cache files (Library/Caches)" [A-CACHE]. Get it with `url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create:)` [A-URLFOR] [A-BACKUP].
- "The system periodically purges these directories" (`/tmp` and `/Library/Caches`) [A-BACKUP]. "Apps should never rely on the existence of cache files". Put them in a subdirectory with the bundle identifier as its name [A-FSPG].

Events:

- `magnify(with:)` "Informs the receiver that the user has begun a pinch gesture". "The event will be sent to the view under the touch in the key window" [A-MAG]. `NSEvent.magnification` gives the change to add to the current scale [A-EVMAG].
- `scrollWheel(with:)` informs the receiver that the scroll wheel moved. "The default implementation passes this message to the next responder" [A-WHEEL]. `modifierFlags` gives the pressed modifier keys [A-MOD]. `scrollingDeltaY` is the preferred delta. When `hasPreciseScrollingDeltas` is `false`, multiply it by a line height [A-DELTA] [A-PREC].
- Inference: an `NSView` that overrides `scrollWheel(with:)` gets the scroll event, and it can test `.command` in `modifierFlags` to zoom. The pages above do not say which view gets a scroll wheel event first (unconfirmed).

## Sources

New Hindenburg sources (the other tags are in `docs/research/timeline-playback.md`):

- [HM] Hindenburg Journalist 1.21 user guide for macOS: https://www.willyurman.com/teaching/handouts/Hindenburg_Journalist.pdf
- [HW] Hindenburg Journalist guide for Windows: http://hindenburgsystems.com/wordpress/wp-content/uploads/2010/07/Hindenburg-Journalist-Guide-Windows.pdf
- [HR] PRO 2 release notes: https://hindenburg.com/support/release-notes/hindenburg-series/
- [Rnnnn] build nnnn at `https://hindenburg.com/release-notes-hindenburg-pro_version-2/<page>/`: [R2558] pro-v2_build-2558, [R2570] pro-v2_02-build-2570, [R2572] pro-v2_02-build-2572, [R2600] pro-v2_02-build-2600, [R2604] pro-v2_02-build-2604, [R2606] pro-v2_02-build-2606, [R2610] pro-v2_02-build-2610, [R2630] pro-v2_03-build-2630, [R2744] pro-v2_05-build-2744
- [KB-wave] Why do the waveforms look the way they do: https://hindenburg.uservoice.com/knowledgebase/articles/1958584-why-do-the-waveforms-look-the-way-they-do-in-hinde
- [KB-all] Knowledge base, all articles: https://hindenburg.uservoice.com/knowledgebase/articles/all
- [UV-freeze] Freeze playhead and scroll tracks: https://hindenburg.uservoice.com/forums/224350-general/suggestions/37659652-freeze-playhead-and-scroll-tracks
- [UV-halfscreen] Drag view / jump half screen: https://hindenburg.uservoice.com/forums/224350-general/suggestions/38797762-drag-view-jump-half-screen
- [UV-colors] I want more colors: https://hindenburg.uservoice.com/forums/224350-general/suggestions/9627570-i-want-more-colors
- [F-colours] PRO 2 feature page "Colours" (no text on 2026-09-25): https://hindenburg.com/products/hindenburg-pro-2/features/colours/
- [N-center] Narrator, center playhead after zoom: https://hindenburg.com/data/functions/narrator-preferences-interface-center-playhead-after-zoom/ (video https://www.youtube.com/watch?v=AiVAFHWwJxQ)
- [N-wheel] Narrator, mouse wheel zooms around playhead: https://hindenburg.com/data/functions/narrator-preferences-mouse-wheel-zooms-around-playhead/
- [N-trackh] Narrator, automatic track height: https://hindenburg.com/data/functions/narrator-preferences-automatic-track-height/

Official Hindenburg videos (https://www.youtube.com/watch?v=<id>), description and frames:

- [V-autoscroll] uIw05vV-iX0 (https://hindenburg.com/data/functions/view-automatic-scroll/)
- [V-trackup] 00CSEJ7ieWM (https://hindenburg.com/data/functions/view-increase-track-height/)
- [V-trackdown] qACWn5OcGLk
- [V-grid] 2CriZCnzZo8 (https://hindenburg.com/data/functions/view-grid-enable/)
- [V-finegrid] OHx9PAN4nJc (https://hindenburg.com/data/functions/view-grid-fine-grid/)
- [V-tracks] XjAfkRcByws (https://hindenburg.com/data/functions/navigate-tracks-up-down/)
- [V-zoomin] Nsnt3yF2FUk, [V-zoomout] AvAtqWWL1qk, [V-marker] wd4SjWBdloM, [V-inout] sx-JseHItFU, [V-drag] P8YW91vfCH8, [V-region] 47ExzZPf1ZU, [V-esc] yCQOGO7gUME, [V-peaks] C45ZhqutWv8

Apple (https://developer.apple.com/documentation/<path>):

- [A-CV] swiftui/canvas
- [A-CVI] swiftui/canvas/init(opaque:colormode:rendersasynchronously:renderer:) and swiftui/canvas/rendersasynchronously
- [A-TV] swiftui/timelineview
- [A-TA] swiftui/timelineschedule/animation and swiftui/timelineschedule/animation(minimuminterval:paused:)
- [A-CL] quartzcore/calayer
- [A-SL] quartzcore/cashapelayer
- [A-RP] appkit/nsview/layercontentsredrawpolicy-swift.property
- [A-RPO] appkit/nsview/layercontentsredrawpolicy-swift.enum/onsetneedsdisplay
- [A-RPN] appkit/nsview/layercontentsredrawpolicy-swift.enum/never
- [A-WUL] appkit/nsview/wantsupdatelayer
- [A-UL] appkit/nsview/updatelayer()
- [A-SV] appkit/nsscrollview
- [A-DOC] appkit/nsscrollview/documentview
- [A-SCR] appkit/nsview/scroll(_:)
- [A-AM] appkit/nsscrollview/allowsmagnification
- [A-MG] appkit/nsscrollview/magnification
- [A-MIN] appkit/nsscrollview/minmagnification
- [A-MAX] appkit/nsscrollview/maxmagnification
- [A-SMC] appkit/nsscrollview/setmagnification(_:centeredat:)
- [A-FIT] appkit/nsscrollview/magnify(tofit:)
- [A-PREP] appkit/nsview/preparecontent(in:)
- [A-PCR] appkit/nsview/preparedcontentrect
- [A-DL] appkit/nsview/displaylink(target:selector:)
- [A-CADL] quartzcore/cadisplaylink
- [A-CVDL] corevideo/cvdisplaylinkcreatewithactivecgdisplays(_:)
- [A-FSO] dispatch/dispatchsource/makefilesystemobjectsource(filedescriptor:eventmask:queue:)
- [A-FSE] dispatch/dispatchsource/filesystemevent
- [A-FSEW] dispatch/dispatchsource/filesystemevent/write, /delete, /rename, /extend, /attrib, /revoke
- [A-CACHE] foundation/filemanager/searchpathdirectory/cachesdirectory
- [A-URLFOR] foundation/filemanager/url(for:in:appropriatefor:create:)
- [A-BACKUP] foundation/optimizing-your-app-s-data-for-icloud-backup
- [A-FSPG] File System Programming Guide, macOS Library directory: https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/MacOSXDirectories/MacOSXDirectories.html
- [A-MAG] appkit/nsresponder/magnify(with:)
- [A-EVMAG] appkit/nsevent/magnification
- [A-WHEEL] appkit/nsresponder/scrollwheel(with:)
- [A-MOD] appkit/nsevent/modifierflags-swift.property
- [A-DELTA] appkit/nsevent/scrollingdeltay
- [A-PREC] appkit/nsevent/hasprecisescrollingdeltas
