# macOS UI shell for a pro audio app

Date: 2026-09-27

This document gives the facts and the recommendations for the UI shell run of Release 2: the window anatomy, the toolbar, the panes, horizontal navigation without scroll bars, accessibility, localization, and the performance rules. It builds on decisions 0014 (the window shell), 0016 (the transport), 0017 (the timeline view), 0020 (the gesture model and the 16 ms budget), and 0022 (the lane layer), and on `docs/research/timeline-view.md`. It does not repeat them.

A sentence that starts with "Inference:" is our reading of the sources. A claim that no source or probe confirms has the mark "(unconfirmed)". The source tags are in the Sources section.

## 1. The user request and the state today

The user asks for:

- An easy but powerful UI with a good look and no drop in performance.
- Toolbar icons, and controls in the title bar where macOS supports them.
- No scroll bars that show at all times. The app follows the macOS setting "Show scroll bars". Horizontal navigation works by other means.
- A track header panel that the user can resize (backlog, 2026-09-26).

The backlog has a user report: "there is no visible horizontal scroll bar or other way to scroll horizontally".

The window today (`SessionView.swift`, `TransportBar.swift`):

- One `NSWindow` per package with an `NSHostingController` of `SessionView` (0014). The window has no toolbar.
- A SwiftUI column: the banners, then the transport bar (Record, Stop, and Play as text buttons, and the time `h:mm:ss.mmm`), then a Monitor Inputs check box, then the timeline pane.
- The timeline pane is an `NSScrollView` (`TimelineScrollView`). The horizontal ruler is an `NSRulerView`. The track headers are SwiftUI rows in the vertical ruler, 340 pt wide, fixed (`TrackHeaderRuler.width`).
- The meter of a track is a SwiftUI `ProgressView` in its header, during a take or a monitor only.
- The transport time is a SwiftUI `Text` that reads `studio.playhead`. So it updates SwiftUI at each playhead poll (about 33 ms).

## 2. How other apps lay out the window

### Hindenburg PRO 2

- The toolbar at the top holds "buttons for the main editing actions like Cut, Paste, Insert, Clear, Split" [BZ]. Import is on the top toolbar [BZ].
- The transport and the time box are at the bottom left. The Voice Meter is also at the bottom left [BZ]. This walkthrough shows version 1.x (2020). The PRO 2 position is unconfirmed.
- The track headers are to the left of each track: volume, pan, effects, mute (M), and solo (S) [BZ].
- The clipboard is "docked on the right of the workspace" [BZ]. In PRO 2, "The clipboards can collapse and expand, and even nest" [PN]. Favorites is a clipboard that all sessions share [HS-fav].
- PRO 2 redrew the icons and controls for high-resolution screens. Tracks can have different heights. Clips can have colors [PN].
- The View menu has Toolbars > Transport [V-transport in `timeline-playback.md`].
- No source shows an overview strip in Hindenburg (unconfirmed).

### Logic Pro and GarageBand

- The control bar runs across the top. It holds the transport buttons, the LCD (the playhead position, tempo, time signature, and key), the Metronome and Count-in buttons, and other controls. The user can customize it [LP-cb] (search excerpt; the page text did not load).
- The default transport buttons are left of the LCD (Rewind, Forward, Stop, Play, Record). Mode buttons are right of the LCD [LP-cb] (search excerpt).
- The user can show a Master Volume slider or an output meter in the control bar [LP-cb].
- The inspector opens with a control bar button, View > Show Inspector, or I [LP-insp].
- GarageBand has the same shape: the Tracks area, the Library, Smart Controls, and the Editors. Its LCD shows times down to milliseconds [GB].

### Final Cut Pro

- Zoom In (Command-plus), Zoom Out (Command-minus), Zoom to Fit (Shift-Z), and Vertical Zoom to Fit (Option-Shift-Z) are View menu items [FCP-zoom].
- A Zoom tool (Z) zooms in on a click and zooms out on an Option-click. A drag with the tool zooms to that area [FCP-zoom].
- A Zoom slider is in the Clip Appearance pop-up at the top right of the timeline [FCP-zoom].
- `docs/research/final-cut-pro.md` covers the rest of Final Cut Pro.

### Pro Tools, Ableton Live, Adobe Audition: the overview strip

- Pro Tools: the Universe view is "an overview of the entire Pro Tools session above the tracks pane in the Edit window". A frame shows the part in view. A drag of the frame scrolls the Edit window. Option-7 shows or hides it [PT-u].
- Ableton Live: "The Overview displays the Arrangement's entire layout of clips from start to end and can be used for zooming and navigation." A horizontal drag scrolls. A vertical drag zooms. A double-click in the outline zooms out to the full arrangement [AB].
- Ableton Live: Command-wheel or plus and minus zoom. Z zooms to the time selection. Command-Option-drag pans. Option-wheel over a track changes the track height [AB].
- Adobe Audition: a zoom navigator. A drag scrolls. A drag of the left or right edge of the highlighted area zooms. A right-drag in the navigator or the ruler zooms to a range. A horizontal wheel or a middle-button drag scrolls [AU].

### Ferrite (iPad)

- One pinch gesture zooms from "hours of audio at a glance" down to "individual samples" [FE].
- Ferrite made its own scroll system: the iOS scroll view "would break down" at full zoom on long projects [FE-ts]. Dirigible already uses a document view as wide as the session and draws only the part in view (0017, 0022).

Inference: every app keeps the transport and the time together in one strip. The desktop apps put it at the top (Logic, GarageBand) or at the bottom (Hindenburg 1.x). The apps that navigate long sessions give a whole-session overview with a view frame (Pro Tools, Ableton, Audition), and one zoom gesture for all scales (Ferrite).

## 3. Apple guidance and APIs that apply

### Toolbars (HIG [H-tb])

- "Choose items deliberately to avoid overcrowding." Define which items go to the overflow menu when the window gets narrow. The system adds the overflow menu.
- In macOS, let people customize the toolbar in apps "that people tend to use for long periods of time".
- "Prefer simple, recognizable symbols for items instead of text." Prefer system symbols without borders.
- Three locations: the leading edge (sidebar toggle, then the title), the center (common controls; customizable; they collapse into the overflow menu), and the trailing edge (important items, inspector buttons, search; "remain visible at all window sizes").
- "Group toolbar items logically by function and frequency of use." Keynote example: presentation, playback, insertion. "In general, aim for a maximum of three" groups.
- Keep a text-labeled action apart from a symbol action.
- macOS: "Make every toolbar item available as a command in the menu bar." Not every menu item needs a toolbar item.
- "Reduce the use of toolbar backgrounds and tinted controls" (Liquid Glass change log, 2025-12-16).
- Titles: do not use the app name as the window title. Keep a title under 15 characters when possible.

### Windows, split views, sidebars, inspectors (HIG)

- Do not make custom window frames or controls [H-win].
- Do not put critical information or actions in a bottom bar: people often move a window so its bottom edge is hidden [H-win].
- Split views: "Set reasonable defaults for minimum and maximum pane sizes", so the divider stays visible. "Provide multiple ways to reveal hidden panes", for example a toolbar button and a menu command with a key. "Prefer the thin divider style" (1 pt) [H-split].
- Sidebars: let people hide the sidebar with a button or Show/Hide Sidebar commands in the View menu. Do not hide it by default. Do not put critical items at its bottom [H-side].

### AppKit and SwiftUI facts (macOS 14 minimum)

- `NSWindow.toolbarStyle` (macOS 11): `.unified` puts the toolbar next to the window title; `.unifiedCompact` does the same with smaller margins [A-tbs].
- `NSWindow.subtitle` (macOS 11): "A secondary line of text that appears in the title bar". An empty string removes it [A-sub].
- `NSToolbar.centeredItemIdentifiers` (macOS 13): the items to show together in the center [A-cent].
- `NSToolbarItem.visibilityPriority`: when space is limited, lower-priority items go to the overflow menu first [A-vis].
- `NSToolbarItem.possibleLabels` (macOS 13): all labels an item can show, in the current locale, so the item sizes for the longest [A-pl].
- `NSToolbarItem.paletteLabel`: required when the toolbar is customizable [A-pal]. `menuFormRepresentation`: the menu item in the overflow menu [A-mfr].
- `NSToolbar.allowsUserCustomization` and `autosavesConfiguration`: both default false. Autosave writes the configuration to user defaults under the toolbar identifier [A-cust] [A-auto]. The identifier "should not be localized" [A-tbid].
- Toolbar validation: `validateVisibleItems()` runs during a window update. It does not run for mouse-dragged, scroll-wheel, or key-down events, and it waits 0.85 s after key-up and flags-changed events [A-val]. Inference: toolbar validation adds no cost to a drag event or a wheel event of the lanes.
- `NSToolbarItem.Identifier.toggleInspector` (macOS 14) sends `toggleInspector:` to the first responder. `.inspectorTrackingSeparator` (macOS 14) tracks the inspector divider, only with `fullSizeContentView` [A-ti] [A-its]. `NSTrackingSeparatorToolbarItem` (macOS 11) aligns the toolbar sections with a split view divider [A-tsep].
- `NSSplitViewItem(inspectorWithViewController:)`: on macOS 14 and later, `canCollapse` is true, and the minimum and maximum thickness are the standard inspector width (270 pt), not resizable by default [A-insp]. `NSSplitViewController.toggleInspector(_:)` (macOS 14) [A-tog].
- `NSSplitViewItem(sidebarWithViewController:)`: the translucent material, collapse on resize, `canCollapse` true, the standard size, and a thickness fraction of 0.15 [A-sb].
- `NSSplitViewItem.minimumThickness`, `maximumThickness`, and `holdingPriority` set the pane limits and which pane grows first [A-min] [A-max] [A-hold]. `NSSplitView.autosaveName` saves the divider positions [A-asn].
- `NSTitlebarAccessoryViewController` puts a view in the title bar area, inside an `NSVisualEffectView`. `layoutAttribute` is `.bottom` (default), `.right`, or `.left` [A-tavc] [A-tavl].
- `NSWindow.titlebarAppearsTransparent` makes sense only with `fullSizeContentView` [A-tat]. With `fullSizeContentView`, `NSScrollView.automaticallyAdjustsContentInsets` (default true) insets the content for the title bar and toolbar [A-aci].
- `NSHostingController.sceneBridgingOptions` (macOS 14): as the `contentViewController` of a window, the default is `.all` (`.toolbars` and `.title`). A SwiftUI `.toolbar` then fills the window toolbar, and "Toolbars populated in this manner overwrite any toolbar set on the window using AppKit" [A-sbo] [A-sbt]. WWDC23 says the same [W23].
- SwiftUI `.inspector(isPresented:content:)` and `.inspectorColumnWidth(min:ideal:max:)` are macOS 14 [A-sinsp] [A-sicw]. `HSplitView` is macOS 10.15 [A-hsv]. `.toolbar(id:content:)` gives a customizable toolbar; `ToolbarCommands` adds the menu items [A-tid].
- macOS 26 (build with the Xcode 26 SDK): standard toolbars, sidebars, and inspectors take the Liquid Glass look with no code [W25] [A-lg]. `NSToolbarItem.style = .prominent` and `backgroundTintColor` are macOS 26 [A-sty] [A-btc]. `isBordered = false` removes the glass of a non-interactive item [W25]. `prefersCompactControlSizeMetrics` (macOS 26) keeps the macOS 15 control sizes in a dense view [A-pccs]. The inspector is edge-to-edge glass; the sidebar floats over the content [W25].
- Glass "samples content from an area larger than itself". `NSGlassEffectContainerView` groups glass views into one sampling pass [W25].

### Scroll bars and gestures

- `NSScroller.preferredScrollerStyle` comes from "Show scroll bars" and, with "Automatically based on input device", from the connected pointing devices. When it changes, AppKit sets `scrollerStyle` on every `NSScrollView`. A scroll view with accessory views or legacy scroller subclasses can refuse the overlay style [A-pss].
- The three settings: "Automatically based on mouse or trackpad", "When scrolling: Hide scroll bars until you start scrolling", and "Always: Scroll bars are always shown" [S-app].
- `autohidesScrollers` does not apply to overlay scrollers [A-ahs].
- HIG: "Because scroll indicators aren't always visible, it can be helpful to make it obvious when content extends beyond the view" [H-scroll]. "If you support zoom, set appropriate maximum and minimum scale values" [H-scroll].
- Trackpad: "Pinch with two fingers to zoom in or out". Smart zoom: "Double-tap with two fingers" (Magic Mouse: one finger) [S-mt]. AppKit sends `smartMagnify(with:)` for smart zoom [A-smag].
- A scroll gesture has a `phase` (`mayBegin`, `began`, `ended`, `cancelled`). Momentum events have their own `momentumPhase`. A legacy wheel has phase none [A-ph] [A-mph].
- Shift with a vertical wheel gives a horizontal scroll in most Mac apps [MR] [ST]. Which layer converts it (the HID system or the app) is unconfirmed; the UI shell run checks it with a real mouse.

### Materials and vibrancy

- `NSVisualEffectView`: in-window blending uses the window content as the background. "Toolbars always use in-window blending." AppKit adds the effect views of title bars, popovers, and source lists by itself. Enable vibrancy only in leaf views [A-vev].
- With Reduce Transparency on, "don't use semitransparent backgrounds" [A-rt].
- HIG: do not use Liquid Glass in the content layer. Use it sparingly [H-mat].

### SF Symbols

- The symbols of a year are not available on older systems [H-sf]. The license forbids a symbol, or a look-alike, in an app icon or a logo [H-sf] [SF].
- The toolbar takes the outline variant by default [H-sf].
- The system file `CoreGlyphs.bundle/Contents/Resources/name_availability.plist` gives the year of each symbol (read on macOS 15.7.9; 2023 = macOS 14). All candidates in section 5 are 2023 or older. `inset.filled.leadinghalf.rectangle` is 2024 (macOS 15): do not use it.
- A custom symbol is an SVG template from the SF Symbols app, in an asset catalog [H-sf]. `xcrun actool` is in the toolchain, and the app-icon probe of this run (`probe-icon/compile`) compiles an asset catalog with it. A custom symbol set through `actool` is not probed (unconfirmed). No toolbar item in section 5 needs one.

### Display rates

- `CADisplayLink.preferredFrameRateRange` is macOS 14. By default it is the maximum rate of the display. The system picks a factor of the maximum rate [A-pfr]. `NSScreen.maximumFramesPerSecond` is macOS 12 [A-mfps]. At 120 Hz, a frame is 8.3 ms [W21].

## 4. Probes

Folder: `.scratchpads/runs/2026-09-27-release-2-plan/probe-ui/` (`probe.swift`, `ruler.swift`, `output.txt`). MacBook Pro 2018, Intel, macOS 15.7.9, Swift 6.2, target macOS 14, built with `swiftc -O`. A window showed for about 1 s.

- **U1.** On this Mac, `NSScroller.preferredScrollerStyle` is overlay. So the timeline scroll bar shows only during a scroll. Inference: this is the cause of the user report "no visible horizontal scroll bar", and the scroll bar follows the setting as 0017 (amended) asks.
- **U2.** A scroll view with a horizontal ruler and a vertical ruler keeps the overlay style when it is set, and the legacy style when it is set. The rulers do not force the legacy style.
- **U3.** An `NSHostingController` that is the `contentViewController` of an `NSWindow` has `sceneBridgingOptions` `.toolbars` and `.title` (raw 3); before, it has none (raw 0). A SwiftUI `.toolbar` with three items gave the window an `NSToolbar` with four items (a flexible space was added), with UUID identifiers. `toolbarStyle` was `.automatic`; a set to `.unified` kept the items.
- **U4.** An AppKit `NSToolbar` set after the bridge stayed for 0.4 s with no SwiftUI update. The doc says that the bridge overwrites it [A-sbt]. Inference: an AppKit toolbar needs `sceneBridgingOptions` without `.toolbars`.
- **U5.** A vertical ruler whose `ruleThickness` changes from 340 pt to 160 pt, with `tile()` after each 4 pt step: the clip view inset follows (`contentInsets.left` 340 then 160), and a step takes 0.058 ms. The style stays overlay. So a resizable header panel in the vertical ruler is cheap on the AppKit side. The lanes cost is in section 8.

## 5. Recommended window anatomy

```
+--------------------------------------------------------------------------------------+
| (o)(o)(o) Interview-12   [Rec][Play][Stop]  0:12:03.451   [Split][Cut]  [-][+][<>]  (hp)(^)(i) |  unified toolbar
|           48 kHz - 3 tracks  (subtitle)                                              |
+--------------------------------------------------------------------------------------+
| banners: take state, save error, missing media, record-over (only when present)      |
+-----------------+--------------------------------------------------------------------+
| (header width)  | overview strip: all tracks, markers, in/out, playhead, view frame  |
+-----------------+--------------------------------------------------------------------+
|                 | time ruler: markers, in and out points                             |
+-----------------+--------------------------------------------------------------------+
| track header  | | lanes (IOSurface layer, 0022)                                      |
| arm name meter| |                                                                    |
| route  gain   |<-> drag handle: header width 180...480 pt                          |
+-----------------+--------------------------------------------------------------------+
```

### Title bar and toolbar

- **Style.** `toolbarStyle = .unified`, `titleVisibility = .visible`. The title is the package name without `.dirigible` (HIG: not the app name). The subtitle shows the rate and the track count, and during a take the record time left (today in the transport bar). The toolbar can cut off the subtitle in a narrow window, so the subtitle is not the only warning: a banner shows when the record time left falls under a threshold, before and during a take (plan gate 1 of the Release 2 plan). Do not set `titlebarAppearsTransparent`.
- **Leading edge.** The title. Later, the sidebar toggle for the clipboards (section 6).
- **Center, group 1: transport and time.** Record, Play/Pause, Stop, then the time display. The time display is the one centered item (`centeredItemIdentifiers`), like the Logic LCD. It is an AppKit label with monospaced digits and a fixed width, so a change of the text never lays out the toolbar again. Go to Start and Go to End are optional items in the customization palette. Record has the highest `visibilityPriority`.
- **Center, group 2: edit.** Split, Cut, Copy, Paste, Delete. These are the Hindenburg toolbar actions [BZ]. They go to the overflow menu first (low `visibilityPriority`).
- **Trailing edge: view.** Zoom Out, Zoom In, and Zoom to Session as one `NSToolbarItemGroup`. Then Monitor Inputs as a toggle (it replaces the check box). Then Export. Later, the inspector toggle (`.toggleInspector`).
- **Three groups** (HIG maximum): transport, edit, view.
- **Record look.** macOS 14 and 15: the `record.circle` symbol in `systemRed` with a palette or a tint configuration; `record.circle.fill` during a take. macOS 26: `style = .prominent` with `backgroundTintColor = .systemRed`, behind `if #available(macOS 26, *)`. No continuous symbol animation during a take (section 8, rule P5).
- **Customization.** `allowsUserCustomization = true`, `autosavesConfiguration = true`, a fixed toolbar identifier, and fixed item identifiers (for example `transport.record`). Each item has a `paletteLabel`.
- **Menu parity.** Each toolbar item is also a menu item with its key. The menu items exist today (0015, 0018, 0019). Monitor Inputs has no key yet, so the UI shell run adds one.

SF Symbols for the items (year from `name_availability.plist`; all are macOS 14 or older):

| Item | Symbol | Year |
|---|---|---|
| Record | `record.circle`, `record.circle.fill` | 2020 |
| Play, Pause, Stop | `play.fill`, `pause.fill`, `stop.fill` | 2019 |
| Go to Start, Go to End | `backward.end.fill`, `forward.end.fill` | 2019 |
| Split | `scissors` (or a custom symbol later) | 2019 |
| Copy, Paste | `doc.on.doc`, `doc.on.clipboard` | 2019 |
| Delete | `trash` | 2019 |
| Zoom In, Zoom Out | `plus.magnifyingglass`, `minus.magnifyingglass` | 2019 |
| Zoom to Session | `arrow.left.and.right.square` | 2019 |
| Monitor Inputs | `headphones` | 2019 |
| Export | `square.and.arrow.up` | 2019 |
| Inspector, sidebar | `sidebar.right`, `sidebar.left` | 2019 |
| Overview (View menu) | `rectangle.bottomhalf.inset.filled` | 2021 |

### Content, top to bottom

1. **Banners.** The SwiftUI banners of today (take state, save error, unplaced segments). The transport bar row goes. Its warnings (playback stop, missing media, record-over) become banners of the same kind. HIG puts no critical information in a bottom bar [H-win], so no bottom bar.
2. **Overview strip** (section 7). About 28 pt high, above the time ruler, as wide as the lanes. View > Show Overview, on by default.
3. **Time ruler** (0017). No change.
4. **Track headers and lanes.** The headers stay in the vertical ruler (0017). A drag handle at the trailing edge of the header panel changes its width (section 6).

### Meters

- A per-track meter stays in each track header. It becomes an AppKit view with a `CALayer` bar that the display link sets from `Studio.liveTracks`, not a SwiftUI `ProgressView` (rule P1).
- No master meter in the toolbar. A meter in the toolbar redraws inside the toolbar material (rule P2). A loudness meter (F40, Release R10) goes into the inspector or its own pane, in its own run.

## 6. Panes

### Track header panel (resizable)

- Keep the headers in the vertical ruler (0017, `TrackHeaderRuler`). A drag of the trailing 4 pt of the ruler changes `ruleThickness` and calls `tile()` (U5). The cursor is `resizeLeftRight` (macOS 14; `columnResize` is macOS 15, 0020 C1).
- Limits: minimum 180 pt (arm, a short name, a meter), maximum 480 pt, and never more than 40% of the window width. Default 280 pt. These are calibration values for a manual check.
- The width is an app preference in `UserDefaults`, not in the package. A double-click on the handle sets the default width.
- The header rows adapt to the width: under about 260 pt, the route menu shows only its symbol, with the full text in its tooltip and its accessibility label.
- The header panel draws an opaque background. The backlog reports that the lanes scroll under the header panel; an opaque ruler also fixes what shows through it (the bug run owns the cause).
- Alternative, rejected: an `NSSplitView` pane for the headers beside a second scroll view. It needs a vertical scroll sync between two scroll views, which 0017 avoids.

### Inspector (optional, trailing)

- Use `NSSplitViewItem(inspectorWithViewController:)` with an `NSHostingController` of a SwiftUI form. Set `minimumThickness` and `maximumThickness` (for example 240 to 360 pt) because the macOS 14 default is a fixed 270 pt [A-insp].
- The toolbar item is `.toggleInspector`; the View menu has Show/Hide Inspector with a key (Logic uses I; Dirigible uses I for Set In Point, so use Option-Command-I).
- Add it only in the run that has its first content (for example clip gain and fades). Until then, no inspector.

### Sidebar for the clipboards and Favorites (later, F22 and F23)

- Use `NSSplitViewItem(sidebarWithViewController:)` and the `.toggleSidebar` toolbar item.
- Hindenburg docks the clipboards on the right [BZ]. macOS puts a sidebar on the leading edge and an inspector on the trailing edge [H-tb]. The clipboard run decides the side. Recommendation: leading, so the trailing edge stays for the inspector.

### The window content controller

- When the first side pane comes, the window content becomes an `NSSplitViewController`: the main item holds the `NSHostingController` of `SessionView`, and each side pane is an item. `NSSplitView.autosaveName` keeps the widths.
- The tracking separators need `fullSizeContentView` [A-its]. Then the main item puts the lanes below the toolbar (its safe area), so no lane pixel is under the toolbar material (rule P2).
- Until the first side pane, the content stays one `NSHostingController` (0014). No split view controller for one item.

## 7. Horizontal navigation without scroll bars

Keep the scroll bars on the system setting (U1, U2, 0017 amended). With "Always", legacy scroll bars show, and the user asked for that. Add these paths, so no user needs a scroll bar:

| Input | Action | State today |
|---|---|---|
| Trackpad, two-finger horizontal swipe | Scroll the lanes | `NSScrollView` does it |
| Mouse, Shift with the wheel | Scroll the lanes horizontally | Unconfirmed: check with a real mouse. If AppKit gives a vertical delta, `TimelineScrollView.scrollWheel` swaps the axes when Shift is down and `hasPreciseScrollingDeltas` is false |
| Command with the wheel, pinch | Zoom at the pointer | Done (0017) |
| Smart zoom (two-finger double tap) | Toggle between Zoom to Session and the zoom before, at the pointer | New: `smartMagnify(with:)` [A-smag] |
| Option with the wheel | Change the lane height | New (Ableton [AB]); Hindenburg uses Shift-Command-plus and minus |
| Overview strip: click | Center the view at that time | New |
| Overview strip: drag in the view frame | Scroll | New (Pro Tools, Ableton, Audition) |
| Overview strip: drag a frame edge | Zoom (Audition [AU]) | New |
| Overview strip: double-click | Zoom to Session (Ableton [AB]) | New |
| Page Up, Page Down | Scroll one view width left or right, with a 10% overlap (HIG page scroll [H-scroll]) | New. Shift-Left and Shift-Right are taken (0016) |
| Command-0, H, Command-plus, Command-minus | Zoom to Session, Zoom to Selection, Zoom In, Zoom Out | Done (0017); also in the toolbar |
| Home, End, a seek | The follow shows the playhead | Done (0017) |

The overview strip:

- It shows the whole session at the current window width: one thin row per track with the clip boxes (or the 65536-frame peaks, 0017), the markers, the in and out band, the playhead, and the view frame.
- It is an opaque, layer-backed AppKit view. Its session image renders only when its inputs change (the session, the peaks, the marks, its width), with an `Equatable` value of the drawn inputs as in 0017. The playhead and the view frame are two `CALayer`s: a scroll, a zoom, or a play tick moves a layer frame and draws no pixel.
- The frame-to-x mapping and the hit rules (frame, edge, body) are pure geometry in `DirigibleTimeline`, with tests, as `LaneGeometry` is (0020).
- A narrow clip box is at least 1 px, and adjacent boxes merge per pixel column, so 12,000 clips draw as at most one span per column (0020 L1 has 12,000 clips at fit zoom).
- Accessibility: one element with the role scroll bar, the label "Session overview", and a value of the view start and end as times.

## 8. Performance rules

The shell adds chrome around the lanes. The lane path of 0020 and 0022 does not change. Rules:

- **P1. No SwiftUI update at the display rate.** The time display, the playhead, the meters, and the overview layers take their values in the display-link tick (`TimelineScrollView.displayTick`), outside SwiftUI, as the playhead line does (0017). The time display sets its text only when the millisecond text changes. Test: the `updates` counter of `TimelineLanes` (criterion 24) stays the same during a play of N ticks; add the same counter to the root `SessionView` body for the toolbar and the headers.
- **P2. No material in or over the lane area.** Lanes, rulers, headers, and the overview are opaque. No `NSVisualEffectView`, no glass, and no vibrancy in them. No lane pixel under the toolbar or a title bar accessory: a toolbar uses in-window blending of the content under it [A-vev], and glass samples an area larger than itself [W25]. Inference: a lane that redraws under the toolbar makes the window server blend the toolbar again at each frame. Test: a screenshot check that the top of the overview is at or under the bottom of the toolbar, with `fullSizeContentView` on and off.
- **P3. The chrome draws only on a change of its inputs.** An `Equatable` value of drawn inputs per view (0017). A scroll or a play moves layers only.
- **P4. The header drag stays in the budget.** A header width change changes the lane view width. 0022 says: "A window resize makes new surfaces and renders in full at each step." So each drag event of the handle can cost a new surface and a full lane draw (8.5 to 9.8 ms p95 on the Intel Mac, 0022). Two options: (a) keep one surface capacity for the whole drag (the widest lane view that the drag can reach), then render in full at each event; (b) show only a guide line during the drag and apply the width at the mouse-up. Take (a) when a new `MouseEventBenchmark` case "header drag event" is 16 ms p95 or less; else take (b).
- **P5. No continuous animation in the toolbar.** No pulse or breathe effect on Record during a take. A state change (outline to fill, a color) is one redraw.
- **P6. Toolbar work stays out of the event path.** Toolbar validation does not run for drag, wheel, or key-down events [A-val]. Set each item state from observed values or from `validate`; never from a drag or a tick.
- **P7. The budget.** 16 ms p95 per drag event and per full lane draw at 2880 x 1200 px, optimized (0020, 0022). On a 120 Hz display a frame is 8.3 ms; the backlog item M8 decides the budget at the real refresh rate. The shell adds no work to a lane event, so the acceptance is the 0022 rule: no case of `MouseEventBenchmark`, `FollowScrollBenchmark`, or `LaneRenderBenchmark` is more than 10% or 1 ms (the larger) worse than main, in two alternate pairs (`make bench FILTER=...`). New bench cases: the overview render after an edit (budget 4 ms p95, a calibration value), a header drag event (P4), and a play tick with the time display, the meters, and the overview layers (budget 2 ms p95).
- **P8. Check the look in each system state.** macOS 14 and macOS 26 (Liquid Glass), light and dark, Reduce Transparency, Increase Contrast, "Show scroll bars" set to Always and to When scrolling, a Retina and a non-Retina display, and a 120 Hz display. These are manual checks of the run ledger with `scripts/screenshot.sh`.

## 9. Accessibility and localization

- Each toolbar item has a localized `label`, `paletteLabel`, and `toolTip`. An image-only item uses `NSImage(systemSymbolName:accessibilityDescription:)` with the localized label [A-sym]. That VoiceOver reads the label of an image-only toolbar item is unconfirmed; check it with Accessibility Inspector and VoiceOver.
- Keyboard: every toolbar command is a menu item with a key (HIG [H-tb]). With Keyboard navigation on, Tab reaches the toolbar controls (manual check).
- Custom views: the time display is a static text element with the time as its value. The header drag handle has the role splitter [A-spl] and the header width as its value; increment and decrement change it by 20 pt. The overview is in section 7.
- Reduce Motion: the follow jumps (0017), and nothing in the shell animates.
- Localization (decision 0010): every label, palette label, tooltip, accessibility description, and menu item gets an `L10n` case and a line in `en.lproj` and `es.lproj/Localizable.strings`. `LocalizationTests` checks both tables. Set `possibleLabels` with both languages' strings of the current locale, so a Spanish label ("Ajustar a la sesión") does not cut. The toolbar identifier and the item identifiers are never localized [A-tbid].

## 10. One-way decisions for the UI shell run

1. **AppKit `NSToolbar` or a SwiftUI `.toolbar` through the scene bridge.** Recommendation: AppKit. The window is AppKit (0014). The time display and the meters must update outside SwiftUI (P1). AppKit gives fixed item identifiers for the saved customization (U3 shows UUID identifiers in the bridge), `visibilityPriority`, `possibleLabels`, `centeredItemIdentifiers`, `.toggleInspector`, and the macOS 26 item styles. Set `sceneBridgingOptions` to `[]` (U3, U4), because the default `.all` lets SwiftUI replace the toolbar and the title. `SessionWindow` is the toolbar delegate, and each action calls the same `SessionWindow` method as its menu item.
2. **Side panes: `NSSplitViewController` or SwiftUI `.inspector` / `NavigationSplitView` / `HSplitView`.** Recommendation: `NSSplitViewController`, created when the first side pane comes. It works with the AppKit toolbar (tracking separators, `toggleInspector:`), autosaves the widths, and gets the macOS 26 sidebar and inspector look.
3. **Track header panel: the vertical ruler with a resizable thickness, or a split pane.** Recommendation: the ruler (U5). It keeps one scroll view and the 0017 row sync.
4. **Overview strip: where and how it draws.** Recommendation: in the content above the time ruler (not a title bar accessory, which is inside a visual effect view [A-tavc]); an opaque AppKit view with a session image that renders on change, and two layers; pure geometry in `DirigibleTimeline`. Alternatives: SwiftUI `Canvas` (0017 D3: 30 fps for a full redraw) and the lane renderer at a small scale (its per-column waveform work is more than a clip-box strip needs).
5. **The transport position.** Recommendation: the toolbar center, with the time display as the centered item. Alternatives: a transport row in the content (today), and a bottom bar (HIG: no critical controls there).
6. **Meters.** Recommendation: per-track meters in the headers as layer bars from the display link; no toolbar meter. A loudness meter comes with R10 in its own pane.
7. **The toolbar identifiers.** Customization writes them to user defaults, so a rename later loses the user layout. Fix the names in the decision record.

The UI shell decision record amends 0014 (the toolbar, the subtitle, `sceneBridgingOptions`) and 0017 (the header width, the overview strip, the new navigation inputs).

## Sources

Probe folders: `.scratchpads/runs/2026-09-27-release-2-plan/probe-ui/` (U1 to U5, `output.txt`), and `.scratchpads/runs/2026-09-27-release-2-plan/probe-icon/compile/` (the `actool` asset catalog build of the app-icon research). Symbol years: `/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/name_availability.plist` on macOS 15.7.9.

Apple Human Interface Guidelines:

- [H-tb] Toolbars: https://developer.apple.com/design/human-interface-guidelines/toolbars
- [H-split] Split views: https://developer.apple.com/design/human-interface-guidelines/split-views
- [H-side] Sidebars: https://developer.apple.com/design/human-interface-guidelines/sidebars
- [H-win] Windows: https://developer.apple.com/design/human-interface-guidelines/windows
- [H-scroll] Scroll views: https://developer.apple.com/design/human-interface-guidelines/scroll-views
- [H-mat] Materials: https://developer.apple.com/design/human-interface-guidelines/materials
- [H-sf] SF Symbols: https://developer.apple.com/design/human-interface-guidelines/sf-symbols
- Inspectors (read, no fact used): https://developer.apple.com/design/human-interface-guidelines/inspectors
- [SF] SF Symbols download and license: https://developer.apple.com/sf-symbols/

Apple developer documentation (https://developer.apple.com/documentation/<path>):

- [A-tbs] appkit/nswindow/toolbarstyle-swift.enum, /unified, /unifiedcompact, and appkit/nswindow/toolbarstyle-swift.property
- [A-sub] appkit/nswindow/subtitle
- appkit/nswindow/titlevisibility-swift.property
- [A-cent] appkit/nstoolbar/centereditemidentifiers
- [A-vis] appkit/nstoolbaritem/visibilitypriority-swift.property
- [A-pl] appkit/nstoolbaritem/possiblelabels
- [A-pal] appkit/nstoolbaritem/palettelabel; appkit/nstoolbaritem/label; appkit/nstoolbaritem/tooltip
- [A-mfr] appkit/nstoolbaritem/menuformrepresentation
- [A-cust] appkit/nstoolbar/allowsusercustomization
- [A-auto] appkit/nstoolbar/autosavesconfiguration
- [A-tbid] appkit/nstoolbar/init(identifier:)
- [A-val] appkit/nstoolbar/validatevisibleitems()
- appkit/nstoolbaritemgroup; appkit/nstoolbaritem/isnavigational; appkit/nstoolbaritem/isbordered
- [A-ti] appkit/nstoolbaritem/identifier/toggleinspector
- [A-its] appkit/nstoolbaritem/identifier/inspectortrackingseparator
- [A-tsep] appkit/nstrackingseparatortoolbaritem
- [A-insp] appkit/nssplitviewitem/init(inspectorwithviewcontroller:); appkit/nssplitviewitem/behavior-swift.enum/inspector
- [A-tog] appkit/nssplitviewcontroller/toggleinspector(_:); appkit/nssplitviewcontroller
- [A-sb] appkit/nssplitviewitem/init(sidebarwithviewcontroller:)
- [A-min] appkit/nssplitviewitem/minimumthickness; appkit/nssplitviewitem/cancollapse; appkit/nssplitviewitem/collapsebehavior-swift.property
- [A-max] appkit/nssplitviewitem/maximumthickness
- [A-hold] appkit/nssplitviewitem/holdingpriority
- [A-asn] appkit/nssplitview/autosavename-swift.property; appkit/nssplitview/dividerstyle-swift.enum/thin
- [A-tavc] appkit/nstitlebaraccessoryviewcontroller
- [A-tavl] appkit/nstitlebaraccessoryviewcontroller/layoutattribute
- [A-tat] appkit/nswindow/titlebarappearstransparent
- appkit/nswindow/titlebarseparatorstyle
- [A-aci] appkit/nsscrollview/automaticallyadjustscontentinsets; appkit/nsview/safearealayoutguide
- [A-sbo] swiftui/nshostingcontroller/scenebridgingoptions; swiftui/nshostingscenebridgingoptions
- [A-sbt] swiftui/nshostingscenebridgingoptions/toolbars
- [A-sinsp] swiftui/view/inspector(ispresented:content:)
- [A-sicw] swiftui/view/inspectorcolumnwidth(min:ideal:max:)
- [A-hsv] swiftui/hsplitview
- [A-tid] swiftui/view/toolbar(id:content:); swiftui/toolbaritemplacement; swiftui/view/toolbarrole(_:)
- [A-lg] https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass
- [A-sty] appkit/nstoolbaritem/style-swift.property
- [A-btc] appkit/nstoolbaritem/backgroundtintcolor
- [A-pccs] appkit/nsview/preferscompactcontrolsizemetrics
- appkit/nssplitviewitem/automaticallyadjustssafeareainsets; appkit/nsscrolledgeeffectstyle
- [A-pss] appkit/nsscroller/preferredscrollerstyle; appkit/nsscroller/preferredscrollerstyledidchangenotification
- appkit/nsscrollview/scrollerstyle; appkit/nsscrollview/horizontalscrollelasticity; appkit/nsscrollview/tile()
- [A-ahs] appkit/nsscrollview/autohidesscrollers
- [A-smag] appkit/nsresponder/smartmagnify(with:)
- [A-ph] appkit/nsevent/phase-swift.property
- [A-mph] appkit/nsevent/momentumphase; appkit/nsevent/scrollingdeltax
- appkit/nsscrollview/allowsmagnification
- [A-vev] appkit/nsvisualeffectview; appkit/nsvisualeffectview/state-swift.property
- [A-rt] appkit/nsworkspace/accessibilitydisplayshouldreducetransparency
- [A-sym] appkit/nsimage/init(systemsymbolname:accessibilitydescription:)
- [A-spl] appkit/nsaccessibility-swift.struct/role/splitter
- swiftui/view/accessibilitylabel(_:)-1d7jv
- [A-pfr] quartzcore/cadisplaylink/preferredframeraterange
- [A-mfps] appkit/nsscreen/maximumframespersecond
- appkit/nsview/layercontentsredrawpolicy-swift.property

WWDC sessions:

- [W23] What's new in AppKit (WWDC23): https://developer.apple.com/videos/play/wwdc2023/10054/
- [W25] Build an AppKit app with the new design (WWDC25): https://developer.apple.com/videos/play/wwdc2025/310/
- [W21] Optimize for variable refresh rate displays (WWDC21): https://developer.apple.com/videos/play/wwdc2021/10147/
- Demystify SwiftUI performance (WWDC23): https://developer.apple.com/videos/play/wwdc2023/10160/

Apple Support:

- [S-app] Change Appearance settings on Mac: https://support.apple.com/en-za/guide/mac-help/mchlp1225/mac
- [S-mt] Use Multi-Touch gestures on Mac: https://support.apple.com/en-us/102482
- [LP-cb] Customize the control bar in Logic Pro for Mac: https://support.apple.com/guide/logicpro/customize-the-control-bar-lgcp5bdd6d9d/mac and Control playback in Logic Pro: https://support.apple.com/guide/logicpro/control-playback-with-the-transport-buttons-lgcp0b07c0c9/10.7/mac/11.6.1 (search excerpts; the page text did not load)
- [LP-insp] Logic Pro for Mac inspector interface: https://support.apple.com/guide/logicpro/inspector-interface-lgcpe9cc3b1d/mac
- [GB] GarageBand for Mac User Guide: https://support.apple.com/guide/garageband/welcome/mac and release notes: https://support.apple.com/en-us/109515
- [FCP-zoom] Zoom in to and out of the timeline in Final Cut Pro for Mac: https://support.apple.com/guide/final-cut-pro/zoom-in-to-and-out-of-the-timeline-ver4e2edcc/mac

Other apps:

- [BZ] Buzzsprout, Hindenburg Journalist Pro review and walkthrough (2020): https://www.buzzsprout.com/blog/hindenburg-journalist-review-and-walkthrough
- [PN] Podnews, Review: Hindenburg PRO v2: https://podnews.net/article/hindenburg-pro-v2-review
- [HS-fav] Hindenburg PRO 2 Clipboard feature: https://hindenburg.com/products/hindenburg-pro-2/features/clipboard/
- Hindenburg PRO guides (no layout text): https://hindenburg.com/academy/guides/guides-hindenburg-pro/
- [PT-u] Production Expert, Pro Tools Universe window: https://www.production-expert.com/production-expert-1/how-to-use-the-pro-tools-universe-and-video-universe-windows and Sound On Sound, Navigating large sessions: https://www.soundonsound.com/techniques/pro-tools-navigating-large-sessions
- [AB] Ableton Live 12 manual, Arrangement View: https://www.ableton.com/en/manual/arrangement-view/
- [AU] Adobe Audition, view, zoom, and navigate audio: https://helpx.adobe.com/audition/using/viewing-zooming-navigating-audio.html
- [FE] Ferrite in depth: https://www.wooji-juice.com/products/ferrite/in-depth
- [FE-ts] TapSmart, Ferrite creator Q&A (search excerpt; the page was not read): https://www.tapsmart.com/features/classics-ferrite/
- [MR] (search excerpt) MacRumors forum, Shift with the mouse wheel: https://forums.macrumors.com/threads/scrolling-horizontally-with-shift-mouse-wheel.2371269/
- [ST] (search excerpt) ScrollTest, horizontal scroll test: https://www.scrolltest.io/horizontal-scroll-test
