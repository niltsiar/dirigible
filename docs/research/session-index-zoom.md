# Research: session index (F76) and waveform vertical zoom (F78)

Date: 2026-10-28

Tags: P = primary source (vendor guide, vendor page, vendor video). S = secondary. "Inference:" = not read in a source. "Unconfirmed" = searched, not found. Repo research already known is cited as "repo" and not repeated: `docs/research/final-cut-pro.md` section 4, `docs/research/macos-ui-shell.md`, `docs/research/logic-garageband-update.md`, `docs/research/track-header.md`.

## 1. Final Cut Pro timeline index

- Placement: "The timeline index appears to the left of the timeline." Index button at the top-left corner of the timeline, or Shift-Command-2, shows and hides it [IX] (P).
- Three buttons at the top switch the list: Clips, Tags, Roles [IX] (P). Newer guide versions add a Captions tab [FIND-S] (S, search excerpt of Apple text).
- Clips tab: "a list of the clips used in the timeline, ordered chronologically" [IX] (P). So the list follows the timeline order, not an alphabetical order.
- Clips columns: Name, Position (timecode), Video Roles, Audio Roles, Notes, Active Angle (multicam). Not all show by default. Control-click a column heading to choose [IX] (P).
- Clips filter buttons (bottom): all, video, audio, titles [IX] (P).
- Tags tab: keywords and markers (standard, chapter, to-do incomplete, to-do completed), ordered chronologically. "All of the tags are shown by default" [IX] (P).
- Tags filter buttons (bottom): markers, keywords, analysis keywords, incomplete to-dos, completed to-dos, chapter markers [IX] (P). There is no separate "All" button on this tab; all shown is the default state.
- Roles tab: click a role name to highlight its clips in the timeline. A check box turns the role on or off for playback [IX] (P). This is role control, not a list of items.
- Click: "When you select an item in the timeline index, the playhead automatically moves to the beginning of the item" [IX] (P). One click selects and seeks. No double-click rule is in the guide (unconfirmed).
- Follow: "When you play a project, the playhead moves down the list of items in the timeline index" [IX] (P). The guide says an index playhead "appears in the list". Whether the row under the playhead gets a highlight is not described (unconfirmed).
- Rename in place: click a name in the Name column, press Return, type the new name [IX] (P). Notes and role columns also edit in place [IX] (P).
- Arrow keys in the list: unconfirmed.
- Search field: it is at the top of the index. You can search clips, keywords, markers (including to-dos), and captions [FIND-S] (S, search excerpt). The guide section "Search for items in the timeline index" did not load in full (unconfirmed detail).
- Command-F: "With the timeline active, choose Edit > Find (or press Command-F)". Apple's tip says this opens the index with the search field active and ready for a term [FIND-S] (S, search excerpt of the Apple text; the primary page body was cut off).
- The Find guide says "You can also use the timeline index to search and filter items in the timeline" [FIND] (P).

## 2. Final Cut Pro waveform size

- Clip Appearance button: top-right corner of the timeline. The controls appear when you click it [CA] (P).
- Six preset buttons, left to right, with keys Control-Option-1 to Control-Option-6: large waveforms only, large waveforms with small filmstrips, equal sizes, small waveforms with large filmstrips, large filmstrips only, clip labels only [CA] (P).
- "To increase the size of audio waveforms for timeline clips, press Control-Option-Up Arrow. To decrease the size ... press Control-Option-Down Arrow" [CA] (P). The key acts on "audio waveforms for timeline clips", so it is a waveform size control, separate from the Clip Height slider.
- Clip Height slider: "drag the Clip Height slider to the left to decrease the clip height, or to the right to increase" [CA] (P). It sets clip height, not waveform amplitude.
- Check boxes in the same panel: Clip Names, Angles, Clip Roles, Lane Headers, Duplicate Ranges [CA] (P).
- Amplitude or height: the guide says "size of audio waveforms". Whether it scales the sample amplitude inside a fixed clip height or changes the share of the clip that the waveform fills is not said (unconfirmed). Inference: with video clips the control moves the share between waveform and filmstrip.
- Per project or global: the page does not say (unconfirmed).
- Separate feature: Control-Z toggles Zoom to Samples. This is horizontal zoom to sample level, not amplitude [FCP-WZ] (P).

## 3. Hindenburg PRO

- Markers view: View > Markers, Option-Command-M (Journalist 1.21, Mac). "Jump to marker: click in markers list." Rename is Enter. The list has one row per marker with number, name, and time (repo `docs/research/edit-commands.md` line 84, from vendor videos) [HJ] p. 12, 59 to 60 (P), [HKS] (P).
- A marker row can set the In point (i) or the Out point (o). Command-click selects a second row [HJ] p. 60 (P).
- PRO 2 shortcut page: marker "Goto" is keys 3 to 0 "(or double-click a marker in the list)" [HKS] (P). So PRO 2 uses a double-click to seek. Journalist 1.21 says a click. Inference: the behavior changed or the two texts differ. Unconfirmed which.
- Chapters view: View > Chapters, Option-Command-H. A chapter has time, title, image, URL [HJ] p. 61 (P). Right-click a marker to make it a chapter [HJ] p. 62 (P). Markers and chapters are two separate lists, not one merged list.
- Clipboard panel: View > Clipboard, Option-Command-C. It is docked on the right of the workspace (repo `macos-ui-shell.md` line 35). In PRO 2 it has groups, sub-groups, and search (repo `edit-commands.md` line 67, from a vendor video). Enter renames a clip; Control-Enter pastes a clip [HKS] (P). It lists soundbites that the editor puts there, not the clips on the timeline.
- No list of the timeline clips is in the guide list or the shortcut page (unconfirmed after reading both).
- No search field for markers or chapters is documented (unconfirmed).
- Waveform: only View > Waveforms > Enabled and Peaks Only, with no key. No amplitude zoom is in the guide list, the shortcut page, or the Journalist guide [HJ] p. 18, [HKS], [HG] (P). Nothing found in the 2.0 build 2544 or 2.02 build 2604 notes seen in search excerpts [HRN] (S).
- Track height: Zoom Track Height + and -, Shift-Command-plus and Shift-Command-minus (Journalist, Mac); Shift-Control-plus and minus on the PRO 2 page. It changes all tracks together [HJ] p. 95, [HKS] (P). Zoom is Command-plus and Command-minus, selection zoom is H [HJ] p. 36, 95 (P).

## 4. Logic Pro

- Open the Marker List: List Editors button in the control bar, then Marker; or View > Show List Editors, then Marker [LML] (P, 10.1 guide). In the 9.1.6 manual: Lists button, Marker tab. Default keys there: Toggle Marker List = K, Open Marker List (window) = Option-M [LML9] (P, old version). Current default keys are not in the guide (unconfirmed).
- Columns: name, bar position, length: "showing the name, bar position, and length of each marker" [LML] (P). Position edits by drag or by double-click and typing [LML-S] (S, search excerpt of the Apple 10.1 page).
- Click: "Clicking a marker's name moves the playhead to that marker's position" [LML] (P). Option-click with the Finger tool sets the locators to the marker; click-hold plays until release [LML9] (P).
- Rename in place: double-click the Marker Name column, or edit the Marker Text area [RN-S] (S, search excerpt of the Apple 10.1 page).
- Search or filter: not covered by the guide pages read (unconfirmed). Inference: the Marker List has no search field.
- Waveform Zoom button: in the Tracks area menu bar. "Click-hold the Waveform Zoom button ..., then drag the slider vertically to zoom in or out" [LSZ10] (P, 10.1). In 9.1.6 a click toggles the zoom level and the button "resizes the waveform in all audio regions" [LWZ-S] (S, search excerpt). The 9.1.6 manual states: "This is a purely visual function. The amplitude (level) of the waveform is not affected" [LWZ9] (P). The 10.1 guide says it zooms "the amplitude of the waveforms in audio regions" [LSZ10] (P). So the zoom is a display scale of all audio regions, not per region.
- Key commands: Waveform Vertical Zoom In, Out, and fixed x1 (Normal), x2, x4, x8 exist [LWZ9] (P). Default keys are not documented (unconfirmed). A forum post names Control-Option-plus and minus for Logic 9 [LOGIC-F] (S, one user, old). Save Zoom Setting and Recall Zoom Setting key commands exist [LSZ10] (P).
- Range: the guide gives the steps x1, x2, x4, x8 for the fixed commands. The slider range is not stated (unconfirmed).
- Saved with the project: not stated (unconfirmed).

## 5. GarageBand for Mac

- Marker list: none found. Arrangement markers sit on an Arrangement track at the top of the Tracks area. Show it from the Track menu. A new marker is eight bars long, and you can rename it [GB-AM] (P). It is a lane, not a list.
- Zoom: the Tracks area guide names only the horizontal zoom sliders in the ruler [GSZ] (P). No vertical zoom, track height, or waveform amplitude zoom is documented (unconfirmed).

## 6. Descript and Audition

- Descript: the marker icon next to the playback controls "view[s] all markers in your script and jump[s] between sections". Markers also show as section headers and as timeline bookmarks. Click a marker label to rename it. The help page names no search field and no key [DS-M] (P). A fact for design: the list is a popup next to transport, not a pane.
- Audition: the Markers panel opens from the Window menu. Double-click a marker moves the playhead and, for a range marker, selects the range. Duration and Type columns can be hidden in the panel menu. Start (and End, Duration) values can be typed in the panel [AU-MK-S] (S, search excerpts; the Adobe page returned HTTP 403). A search field is not mentioned (unconfirmed).
- Audition vertical zoom: Alt-equals and Alt-minus (from search excerpts). Unconfirmed here.

## 7. macOS HIG and VoiceOver

- Search placement: "Put a search field at the trailing side of the toolbar for many common uses", for apps that search across columns, so the selection stays visible in the detail view. "Include search at the top of the sidebar when filtering content or navigation there" [H-SF] (P).
- Search behavior: "If possible, start search immediately when a person types." Use placeholder text to say what you can search. A scope bar and tokens can narrow a search [H-SF] (P).
- Command-F and Esc: the search-fields page states neither. The Keyboards page lists Command-F as "Open a Find window", Option-Command-F as "Jump to the search field control", and Esc as "Cancel the current action or process" [H-KB] (P). So Option-Command-F is the system key that focuses a search field. Esc clearing a field is the AppKit field behavior, not an HIG rule (unconfirmed in the HIG).
- Sidebar: "appears on the leading side of a view". Let people hide it with a button or Show Sidebar and Hide Sidebar in the View menu. Avoid putting critical actions at the bottom of a sidebar. It needs "a large amount of vertical and horizontal space" [H-SB] (P).
- Inspector: trailing side (repo `docs/research/ui-chrome-hig.md` lines 48 to 51). Option-Command-I is the HIG key for "Display an inspector window" [H-KB] (P).
- Control: "Avoid using the Control key as a modifier. The system uses Control in many systemwide features". Option: "sparingly for less-common commands or power features". Command is the main modifier [H-KB] (P).
- Control-Up and Control-Down already mean "Move focus to another value or cell within a view, such as a table" [H-KB] (P).
- VoiceOver: "By default, you can use either Caps Lock or Control-Option as the VoiceOver modifier" [VO] (P). So Control-Option-Up is VO-Up when VoiceOver is on. The VoiceOver keyboard page lists VO-Shift-Up and VO-Shift-Down but not VO-Up or VO-Down alone (unconfirmed what they do). Inference: with VoiceOver on and Control-Option as the modifier, VoiceOver can take Control-Option-Up before the app. FCP ships this pair anyway [CA] (P).

## Design facts for Dirigible

State on 2026-11-24: decided and built. F76 and F78 are in the app. The index search key is Shift-Command-F (Edit > Find in Session Index), not Command-F. The waveform zoom steps a range in dB (View > Waveform Zoom In and Out, Option-Command-Up Arrow and Down Arrow), not the steps x1 to x8 of Logic. The guide section "Find a clip, a marker, or a chapter" and decision 0023 hold the present rules.

1. Placement: FCP puts the index in a pane left of the timeline [IX]; the HIG puts a sidebar on the leading side and the inspector on the trailing side. A leading pane that holds the index agrees with both (repo `macos-ui-shell.md` line 228 also picks leading).
2. Order and click: FCP lists clips and tags in timeline order, and a click selects the item and moves the playhead to its start [IX]. Logic does the same on a marker name [LML]. Use one click to seek. Hindenburg PRO 2 uses a double-click [HKS], which is the slower way.
3. Scope: references split by type. FCP has Clips and Tags tabs with type filter buttons [IX]. Hindenburg has separate Markers and Chapters views [HJ]. Logic has one Marker List. Nobody merges clips, markers, and chapters in one flat list, so F76 needs a type filter (All, Clips, Markers, Chapters) as FCP has.
4. Search: only FCP documents a search field in the index, opened by Command-F with the timeline active [FIND-S]. Logic, Hindenburg markers, Descript, and Audition document none. Command-F is the standard "Find" key; the HIG key to focus a search field is Option-Command-F [H-KB]. Inference: bind Command-F to the index search when the index is open; confirm the key does not clash with the text field editor.
5. Search field placement: the HIG puts a filter field at the top of the sidebar when it filters that sidebar [H-SF]. Start the filter on typing, with placeholder text such as "Search clips, markers, chapters".
6. Rename in place: FCP (click, then Return) and Logic (double-click) rename in the list [IX] [RN-S]; Hindenburg uses Enter on the selected marker [HJ]. Return or Enter on the selected row to rename is the shared pattern.
7. Follow the playhead: FCP moves an index playhead down the list during play [IX]; a row highlight for the current item is not documented. A highlight costs time if it redraws the list on every tick (repo rule: no per-tick work outside the playhead layer).
8. Zoom key: FCP uses Control-Option-Up and Down for waveform size [CA]. The HIG tells apps to avoid Control as a modifier, and VoiceOver uses Control-Option [H-KB] [VO]. Inference: a Dirigible key without Control (for example Option-Command-Up and Down, or Command-Option plus another pair) avoids the VoiceOver clash. Logic has no documented default key [LWZ9].
9. Zoom meaning: Logic's Waveform Zoom is a view scale of all audio regions with steps x1, x2, x4, x8 and a slider; it does not change the audio level [LWZ9]. FCP separates "waveform size" from "Clip Height" [CA]. Dirigible already has lane height (repo `track-header.md`); F78 should be a separate control that scales the drawn amplitude only.
10. Control placement: Logic puts a Waveform Zoom button in the Tracks area bar [LSZ10]; FCP puts waveform size in the Clip Appearance panel at the timeline top right [CA]. Both keep it next to the lanes, not in the main toolbar.
11. Scope of the zoom: Logic zooms all audio regions at once [LWZ-S]. FCP does not say if per project or global. Hindenburg has no amplitude zoom, only track height for all tracks [HJ] [HKS]. A single global view setting is the common pattern; whether it is saved with the session is open.
12. Cost: no source discusses cost. Inference: scaling the drawn peak height at draw time needs no new peak data; an amplitude change then only invalidates the lane images, as a height change does.

## Open questions

1. Does the FCP waveform-size key scale the sample amplitude inside a fixed clip height? Unconfirmed; a hands-on test on a Mac with FCP would settle it.
2. Is the FCP Clip Appearance setting saved per project or per app? Unconfirmed.
3. Does the FCP index highlight the row at the playhead? Unconfirmed. Does it move with the arrow keys? Unconfirmed.
4. Does Command-F in FCP focus the field when the index is already open? The Apple tip says it opens the index with the field active (search excerpt only).
5. Logic: default keys of Waveform Vertical Zoom In and Out; current default key of the Marker List; whether the Marker List filters. All unconfirmed for Logic Pro 11 and 12.
6. Hindenburg PRO 2: single click or double-click on a marker row? The Journalist 1.21 guide says click; the PRO 2 shortcut page says double-click.
7. Does VoiceOver take Control-Option-Up and Down before an app? No Apple page read says so. A test with VoiceOver on a built app would answer it (not run).
8. Audition: markers panel search field, and the exact vertical zoom key. The Adobe pages returned HTTP 403.
9. For the planner: should the index show clips on all tracks (a long list for 12,000 clips) or only the selected track? No reference app covers a multi-track clip list; FCP lists one timeline of connected clips.

## Sources

- [IX] FCP, View your project in the timeline index (P): https://support.apple.com/guide/final-cut-pro/view-your-project-in-the-timeline-index-ver4e30596/mac (read 2026-10-28; the page body was cut off before the search section)
- [FIND] FCP, Find clips and projects (P): https://support.apple.com/guide/final-cut-pro/ver65764b45/mac
- [FIND-S] Search excerpts of the Apple FCP pages on the index search field and Command-F (S): https://support.apple.com/guide/final-cut-pro/ver4e30596/mac and https://support.apple.com/guide/final-cut-pro/ver65764b45/mac
- [CA] FCP, Adjust timeline clip appearance (P): https://support.apple.com/guide/final-cut-pro/adjust-timeline-clip-appearance-verb8e5d346/mac
- [FCP-WZ] FCP, Zoom in to audio waveforms (P): https://support.apple.com/guide/final-cut-pro/ver5c808beb/mac
- [HJ] Hindenburg Journalist 1.21 user guide, macOS, pages 12, 18, 36, 59 to 62, 95, 100 (P, text extracted with PDFKit on 2026-10-28): https://www.willyurman.com/teaching/handouts/Hindenburg_Journalist.pdf
- [HKS] Hindenburg PRO 2 shortcuts (P; Windows notation, no Mac keys): https://hindenburg.com/academy/shortcuts/shortcuts-hindenburg-2-pro/
- [HG] Hindenburg PRO guides list (P): https://hindenburg.com/academy/guides/guides-hindenburg-pro/
- [HRN] Hindenburg PRO 2 release notes, builds 2544 and 2604 (S, search excerpts only): https://hindenburg.com/release-notes-hindenburg-pro_version-2/pro-v2_02-build-2604/ and https://hindenburg.com/release-notes-hindenburg-pro_version-2/pro-v2_build-2544/
- [LML] Logic Pro 10.1, Marker List (P): https://help.apple.com/logicpro/mac/10.1/en.lproj/lgcp31f1cf25.html
- [LML-S] and [RN-S] Search excerpts of Logic Pro 10.1 Marker List and Rename markers (S): https://help.apple.com/logicpro/mac/10.1/en.lproj/lgcp4d438ec1.html
- [LML9] Logic Pro 9.1.6 manual, markers (P, old version): https://help.apple.com/logicpro/mac/9.1.6/en/logicpro/usermanual/chapter_6_section_1.html and https://help.apple.com/logicpro/mac/9.1.6/en/logicpro/usermanual/chapter_6_section_9.html
- [LWZ9] Logic Pro 9.1.6 manual, Waveform Zoom (P, old version): https://help.apple.com/logicpro/mac/9.1.6/en/logicpro/usermanual/chapter_4_section_6.html
- [LWZ-S] Search excerpt of the same 9.1.6 text for "all audio regions" (S).
- [LSZ10] Logic Pro 10.1, Scroll and zoom in the Tracks area (P): https://help.apple.com/logicpro/mac/10.1/en.lproj/lgcpf7c0b924.html
- [LOGIC-F] Logic Users Group thread on key commands (S, one user): https://logic-users-group.com/threads/non-working-key-commands.1109/post-8163
- [GB-AM] GarageBand, Add arrangement markers (P, search excerpt): https://support.apple.com/guide/garageband/gbnd8431c634/mac
- [GSZ] GarageBand, Scroll and zoom in the Tracks area (P): https://support.apple.com/guide/garageband/scroll-and-zoom-in-the-tracks-area-gbndd75e5c48/mac
- [DS-M] Descript, Markers and chapters (P): https://help.descript.com/script-editing/markers-chapters
- [AU-MK-S] Adobe Audition, Working with markers (S, search excerpts, page 403): https://helpx.adobe.com/audition/using/markers.html
- [H-SF] Apple HIG, Search fields (P): https://developer.apple.com/design/human-interface-guidelines/search-fields.md
- [H-SB] Apple HIG, Sidebars (P): https://developer.apple.com/design/human-interface-guidelines/sidebars.md
- [H-KB] Apple HIG, Keyboards (P): https://developer.apple.com/design/human-interface-guidelines/keyboards.md
- [VO] Apple, Control your Mac using keyboard commands with VoiceOver (P): https://support.apple.com/guide/voiceover/vo2681/mac
