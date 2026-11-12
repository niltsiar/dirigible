# Research: reference apps 2 (Audacity, Adobe Audition, and a check of FCP, Logic Pro, Hindenburg PRO)

Date: 2026-11-11

Scope: the session index (F76) and the waveform vertical zoom (F78).

## Headline for the waveform zoom (a dB window has a primary-source precedent)

Audacity's dB waveform view shows the waveform in a window of dB. It has a range in dB (default 60 dB), set in steps of 36, 48, 60, 72, 84, 96, 120, and 145 dB. It is per track and changes the display only. Ctrl+Shift and wheel over the scale change the range. [AU-SRC-WS] [AU-SRC-VRC] [AU-SRC-VZH]

## How to read this file

- A claim has a tag in brackets. The tag is in `## Sources`.
- "Fetched" means the page or file was read in full in this session. "Search only" means a web search tool returned the claim as a summary of the page, and the page itself was not read. A search-only claim is weaker. Treat it as a lead to check.
- "Not found" means no primary source in this session states it. It does not mean the app lacks it.
- "Inference:" means a rule taken from a source by analogy.
- Adobe help pages (helpx.adobe.com) refused automated fetch ("Access Denied"). No bypass was tried. Adobe facts come from the Audition CC 2015 reference PDF (fetched, from the Adobe archive) or from search summaries.
- Hindenburg guide pages do not render without scripts. Hindenburg facts come from search summaries only.
- No build, swift, make, or probe command ran.

## A. Index and list views

### Audacity: Label Editor and label tracks

- The Label Editor is a dialog. Edit > Labels > Label Editor opens it. It shows all labels of all label tracks in one table. Each row is one label. [AU-LE]
- The page text names these cells: Track, Label (the text), Start Time, End Time. Low Frequency and High Frequency show when a label has a spectral selection. [AU-LE]
- The editor lists labels only. It lists no audio clips. [AU-LE]
- Search or filter: not found. The page describes none.
- Sort order and a user sort: not found.
- Open state: the editor opens with the label at the editing cursor selected. If the cursor is not on a label, it selects the label to the left of the cursor and moves the cursor to it. [AU-LE]
- Close state: on close, the cursor goes to the label that was selected. The label is selected in the label track. [AU-LE]
- Space after close moves the view to the label start. A point label plays from its start. A region label plays its range. [AU-LE]
- Click or double-click on a row: the page does not say that a click moves the playhead. Selection moves the cursor only on close. Double-click opens a cell for edit. [AU-LE]
- Rename in place: yes, in the table. Press F2 or double-click a cell to edit it. Enter confirms and moves down to the same cell of the next label. Tab confirms and moves to the next cell. Shift+Tab goes back. [AU-LE]
- Keyboard: arrow keys move between cells. Ctrl+Tab leaves the grid and cycles the buttons. [AU-LE]
- Time cells: Left and Right arrow move between digits. Up and Down arrow change the digit. [AU-LE]
- Insert and Delete buttons add and remove a label. Insert adds a label before the selected row. Delete never removes the label track. [AU-LE]
- Import and Export buttons read and write a labels text file. [AU-LE]
- Multi-select in the table: not found.
- Follow of the play position in the table: not found.
- Shortcut that opens the editor: not found. The menu item shows no key on the pages read. [AU-LM]
- Label track, outside the editor:
  - Tab opens the next label for edit and moves the cursor or selection to it. Shift+Tab goes to the previous label. The list cycles from the last label to the first. [AU-LT]
  - Alt+Right and Alt+Left move the cursor or selection to the next or previous label without opening it. The view centers on the label. [AU-LT]
  - During play, these two commands restart play at the label. [AU-LT]
  - Ctrl+M (Command+period on Mac) adds a point label at the play position during play or record. Ctrl+B adds a label at the selection. [AU-LM]
  - Delete a label: right-click Delete Label. Or remove the text and press Backspace. [AU-LT]
- Limits that the manual states: label text over 260 characters is not reloaded. Hundreds or thousands of labels can make Audacity sluggish. [AU-LT]

### Adobe Audition: Markers panel

- Window > Markers opens the panel. Use the panel to define and select markers. [AUD-REF p.54]
- A marker is a point or a range. [AUD-REF p.54]
- Columns: the panel menu has Markers Display. It shows or hides Duration and Type. The page names Start, End, and Duration as values that you enter. [AUD-REF p.54-55]. The full column list: not found.
- Single click selects the marker. Double-click moves the current-time indicator (CTI) to the marker and selects the area of a range marker. [AUD-REF p.55]
- Multi-select: Shift-click selects adjacent markers. Ctrl-click (Command-click on Mac) selects separate markers. [AUD-REF p.55]
- Rename in place: select the marker, then click the name and type. [AUD-REF p.55]
- Edit position in the list: select the marker and type new Start values, or Start, End, and Duration values for a range. [AUD-REF p.55]
- Buttons in the panel: Add Marker (the M key also adds one), Merge (merges the selected markers, and the first name stays), Delete (deletes the selected markers), Export Audio (saves the audio of the selected ranges to files). [AUD-REF p.54-56]
- A range can be dragged from the Markers panel to the Multitrack Editor. Audition converts it to a clip. [AUD-REF]
- Edit > Marker > Move CTI to Next or Previous moves the CTI to the nearest marker. The shortcut table gives Ctrl+Alt+Right and Ctrl+Alt+Left (Cmd+Option on Mac). [AUD-REF p.55, shortcut table]
- A newer help page says the multitrack Markers panel can show Clip Markers and Session Markers by an icon at the upper right of the panel. [AUD-MK-SEARCH] Search only.
- Search or filter: not found. A search tool query on the current help pages found none. [AUD-MK-SEARCH]
- Sort order and a user sort: not found.
- Follow of the play position in the panel: not found.
- Files panel as a list of clips: not read (page refused fetch). The Files panel lists files, and a double-click opens a file in the Waveform Editor. [AUD-REF p.10] It is not a list of timeline clips.

### Final Cut Pro (confirmation)

All of this is from the Apple page. [FCP-IX]

- The timeline index lists clips, tags (markers and keywords), and roles of the project.
- Index button (top left of the timeline) or Shift-Command-2 shows and hides it. It sits to the left of the timeline.
- The timeline index playhead shows in the list. During play it moves down the list.
- When you select an item, the playhead goes to the start of the item.
- Clips pane: chronological order. Buttons at the bottom filter by All, Video, Audio, or Titles. Control-click a column heading to choose columns (not all show by default). Columns named: Name, Position, Video Roles, Audio Roles, Notes, Active Angle.
- Rename a clip: click the name in the Name column, press Return, type the new name.
- Tags pane: chronological. Buttons at the bottom filter by markers, keywords, analysis keywords, incomplete to-dos, completed to-dos, and chapter markers.
- Search: the field is at the top of the index. Command-F with the timeline active opens the index with the search field active. Choose a pane first (Clips, Tags, or Roles) to search it.
- Search covers clip name, keyword, marker (with to-dos), caption, role, note, reel, scene, camera angle, camera name, custom metadata, and effect name. Auto keywords work too ("missing", "multicam", "compound", "synchronized", "audition").
- A pop-up menu in the search field filters clips: duplicate ranges, video effects, audio effects, missing media, missing effects, retiming, Beat Detection.
- A way to turn off the playhead follow: not found.
- A user sort of the columns: not found.
- Multi-select in the index and what it does: not found on this page.
- Delete from the index: not found on this page.

### Logic Pro (confirmation)

- The Marker List shows every marker with name, bar position, and length. [LG-ML]
- A click on a marker name moves the playhead to the marker. [LG-ML]
- The Create button adds a marker at the playhead. [LG-ML]
- Position: drag vertically in the Position column, or double-click and type a value. Length works the same. [LG-ML] [LG-EM]
- Copy and Paste (Command-C, Command-V) work in the Marker List. [LG-EM]
- The Marker Set pop-up menu selects the set. The Marker Text area edits text of the selected marker. [LG-ML]
- Open it: List Editors button in the control bar, then Marker. Or View > Show List Editors, then Marker. [LG-ML]
- Search or filter in the Marker List: not found.
- Rename in the list: not found on these two pages.
- Follow of the play position: not found.
- Event List and Project Audio Browser: the Event List filters by event type buttons and has no search field. The Project Audio Browser lists audio files with their regions under a disclosure arrow. The only search found is in the All Files Browser. [LG-EVT-SEARCH] Search only.

### Hindenburg PRO (confirmation)

- Markers View: the shortcut page says it is where you see, rename, and go to marker points. [HB-KEYS-SEARCH] Search only.
- The Pro guide says: double-click a marker in the markers list and the playhead goes to that point. [HB-GUIDE-SEARCH] Search only.
- Markers View shortcut: Alt+Cmd+M. Chapters View: Alt+Cmd+H. The Narrator table gives a different key for Chapters (Alt+Cmd+S). [HB-KEYS-SEARCH] Search only.
- Enter: the Pro shortcut table lists Enter as "Edit - Rename: Rename Region". A source that Enter renames a marker: not found. [HB-KEYS-SEARCH] Search only.
- A list of timeline clips and a search: not found.

## B. Waveform vertical zoom

### Audacity

The vertical scale is a ruler at the left of each audio track.

- Control: right-click the vertical scale. The menu has Zoom In, Zoom Out, Reset Zoom, and Half Wave. [AU-VZ] [AU-TCP]
- The same menu switches the scale: Linear (amp), Logarithmic (dB), Linear (dB). [AU-TCP]
- Zoom In halves the displayed amplitude range. Zoom Out doubles it. The zoom is centered on the middle of the waveform. [AU-VZ] [AU-SRC-VZH]
- Limit in source: the displayed range cannot get under 0.001 (the full-scale range is 2.0, from -1.0 to 1.0). Zoom Out stops at -2.0 to 2.0 in the linear scale, which is twice full scale. [AU-SRC-VZH]
- Reset Zoom shows -1.0 to 1.0 again. Half Wave shows slightly more than the top half. [AU-SRC-VZH]
- Mouse: Ctrl (Command on Mac) and wheel over the vertical scale zoom in or out at the pointer. Shift and wheel scroll at the same zoom. [AU-VZ]
- In the dB view, Ctrl+Shift and wheel change the lower dB limit. A source check agrees: Shift and Command together call the next lower or higher dB range. [AU-VZ] [AU-SRC-VRC]
- Inconsistent manual: the Interface Preferences page says Shift and wheel change the lower limit. The Vertical Zooming page and the source say Ctrl+Shift. Trust the source. [AU-PREF-IF] [AU-VZ] [AU-SRC-VRC]
- With the pointer in the middle half of the lane height, the dB limit change keeps the magnification and moves peaks rigidly. Elsewhere it changes the magnification. [AU-SRC-VRC]
- dB range steps in source: 36, 48, 60, 72, 84, 96, 120, 145 dB. The default is index 2, which is 60 dB. The labels tie them to bit depth (for example 96 dB is the range of 16-bit samples and 145 dB of 24-bit samples). [AU-SRC-WS]
- Default range for new tracks: the preference "Meter dB range" in Interface Preferences. It is an app setting. [AU-PREF-IF]
- Scope: per track. The zoom bounds and the dB range are attached to each wave track in source. [AU-SRC-WSC] [AU-SRC-VRC]
- Linear or dB: both. Each track has one of three scales. [AU-TCP]
- View only: the zoom code sets display bounds and does nothing to samples. [AU-SRC-VZH]
- Undo: after a zoom the code calls `ModifyState(true)`, so the zoom enters the undo history. [AU-SRC-VZH]
- Zoom not for label tracks or time tracks. [AU-VZ]
- Shortcut key for vertical zoom: not found.
- Gain line, fade handles, or clip meters moving with the zoom: not found. The track gain slider is in the control panel, not on the waveform. [AU-TCP]
- Clipping: View > Show Clipping in Waveform draws a red vertical line at each clipped sample. A sample is clipped if it touches or exceeds 0 dB. The default is off. Four or more clipped samples in a row also light the meter clip indicator. [AU-VIEW]
- How a waveform that goes past the lane edge is shown after a zoom: not found.
- Saved with the project or the app: not found for the zoom. The two source files read (`WaveformScale.cpp`, `WaveformSettings.cpp`) hold no save code. A save code may exist in another file. The default range is saved in the app preferences. [AU-SRC-WSC] [AU-SRC-WS]

### Adobe Audition

- Amplitude scale: right-click the vertical ruler in the waveform display. Choices: Decibels, Percentage, Sample Values, Normalized Values. [AUD-REF p.46]
- Vertical zoom keys: "Zoom in vertically" is Alt+= (Option+= on Mac). "Zoom out vertically" is Alt+minus (Option+minus on Mac). [AUD-REF shortcut table, 2015]
- A search summary says the current shortcut page lists a vertical zoom pair with the same keys. [AUD-KEYS-SEARCH] Search only.
- Mouse wheel: roll the wheel over the zoom navigator or a ruler. In the Waveform Editor it also works over the waveform. The 2015 text does not say that this wheel zooms the amplitude. Treat it as the time zoom. [AUD-REF p.10-11]
- A community thread says the wheel over the amplitude scale zooms the amplitude. It is not a primary source. Not used. [AUD-COMM-SEARCH]
- Range, steps, scope per track or global, saved or not: not found.
- Gain line, fade handles, and meters moving with the zoom: not found.
- Clipping display at the lane edge: not found.
- Reset of the vertical zoom: not found for the waveform. A "Zoom Out Full" button exists for the time axis. [AUD-REF p.11]

### Final Cut Pro (confirmation)

- Control-Option-Up Arrow is "Increase Waveform Size". Control-Option-Down Arrow is "Decrease Waveform Size". Both are in the View group of the Clip Appearance commands. [FCP-KEYS] [FCP-CA]
- Clip Appearance panel (top right of the timeline): six layout buttons (Control-Option-1 to 6) and a Clip Height slider. [FCP-CA]
- The page says the controls change how the timeline shows clips. Scope per clip or per timeline: the page says "timeline clips" and names no per-clip control. Inference: global to the timeline.
- Amplitude scale (linear or dB), range, steps, reset, gain line moving, and save: not found. The "Audio waveforms" page gives no scale. [FCP-WF]

### Logic Pro (confirmation, and one correction)

- Waveform Zoom button in the Tracks area menu bar: click and hold, then drag the slider vertically. [LG-ZOOM]
- Key commands "Save and Recall Zoom Setting" exist. [LG-ZOOM]
- The Apple page "Key commands for Main Window Tracks" lists default US keys "Waveform Vertical Zoom In = Command-Equal (=)" and "Waveform Vertical Zoom Out = Command-Hyphen (-)". The table is "default key commands included in the U.S. default preset". The page does not list the fixed commands x1, x2, x4, and x8, so their default keys stay unconfirmed (see `docs/research/session-index-zoom.md`). [LG-KEYS]
- A search summary said these two keys need "Enable Complete Features". The text "Complete Features" is not on the fetched page. That qualifier is not confirmed. [LG-KEYS]
- The Audio File Editor amplitude scale shows percentage or sample values. [LG-AMP-SEARCH] Search only.
- Range, steps, scope, save, clipping display: not found.

### Hindenburg PRO (confirmation)

- No amplitude zoom found.
- View > Increase and Decrease track height: Shift+Cmd+Plus and Shift+Cmd+Minus. [HB-WF-SEARCH]
- Waveforms are rectified: light tops are peaks, dark middle is RMS. A "Peaks Only" mode exists. [HB-WF-SEARCH] Search only.

## C. Best option for each sub-point

### C1. Session index and lists

| Sub-point | Best option | Reason | Source |
|---|---|---|---|
| Items in one list | FCP | One pane for clips, markers, chapters, keywords, roles. | [FCP-IX] |
| Columns | FCP | The user picks columns (Control-click a heading). | [FCP-IX] |
| Search | FCP | One field. It covers name, marker, note, role, effect, and more. Command-F opens it. | [FCP-IX] |
| Filter by kind | FCP | Buttons at the bottom of each pane, plus a filter pop-up in the field. | [FCP-IX] |
| Single click | FCP | Select and move the playhead in one click. | [FCP-IX] |
| Double-click | Audition | Double-click moves the CTI and selects the range of a range marker. A single click only selects. | [AUD-REF p.55] |
| Rename in place | Audacity for bulk, FCP for one item | Audacity: F2 or double-click, Enter commits and goes to the next row, Tab goes to the next cell. FCP: click name, Return. | [AU-LE] [FCP-IX] |
| Edit the time in the list | Audition | Start, End, Duration typed in the panel. Logic is close (double-click Position). | [AUD-REF p.55] [LG-ML] |
| Follow of play | FCP | The index playhead moves down the list. A switch to turn it off: not found. | [FCP-IX] |
| Sort | No evidence of a user sort in any app. All list in time order. | Chronological in FCP. Not found elsewhere. | [FCP-IX] |
| Keyboard | Audacity | The whole editor works by keys. Tab and Enter flow through cells. | [AU-LE] |
| Previous or next item by key, outside the list | Audacity and Audition | Alt+Right or Left (Audacity). Cmd+Option+Left or Right (Audition). | [AU-LT] [AUD-REF] |
| Multi-select | Audition | Shift-click and Command-click. Merge, Export Audio, Delete, and drag to Multitrack act on the set. | [AUD-REF p.55-56] |
| Delete from the list | Audition and Audacity | Delete button in both. | [AUD-REF p.55] [AU-LE] |
| Add from the list | Audition, Logic, Audacity | Add Marker, Create, and Insert buttons. | [AUD-REF] [LG-ML] [AU-LE] |
| Play from the list | Audacity | Space after a row selection plays the region of a region label. | [AU-LE] |
| Open key | FCP | Shift-Command-2, and the Index button. | [FCP-IX] |

### C2. Waveform vertical zoom

| Sub-point | Best option | Reason | Source |
|---|---|---|---|
| Key | Logic (default Command-= and Command--), FCP (Control-Option-Up and Down), Audition (Option-= and Option--) | Each has a key pair. | [LG-KEYS] [FCP-KEYS] [AUD-REF] |
| Pointer control | Audacity | Command-wheel on the scale zooms at the pointer. Right-click menu has Zoom In, Out, Reset. | [AU-VZ] |
| Continuous control | Logic | Click-hold slider on the Waveform Zoom button. | [LG-ZOOM] |
| Range and steps | Audacity | Linear zoom in powers of 2 down to 0.001. Eight dB ranges from 36 to 145 dB. | [AU-SRC-VZH] [AU-SRC-WS] |
| Scope | Audacity | Per track. | [AU-SRC-WSC] |
| Scale | Audacity and Audition | Both give the user a choice: linear, dB. Audition adds Percentage, Sample Values, Normalized. | [AU-TCP] [AUD-REF p.46] |
| View only, not sound | Audacity | The code sets display bounds only. | [AU-SRC-VZH] |
| Reset | Audacity (menu item) and Logic (Save and Recall Zoom Setting) | A reset item. A saved zoom to return to. | [AU-VZ] [LG-ZOOM] |
| Shows the current scale | Audacity and Audition | A vertical ruler with values on each track. | [AU-TCP] [AUD-REF p.46] |
| Signal clipping display (not the lane edge) | Audacity | Show Clipping in Waveform: red line for each sample at or over 0 dB. No app was found that shows a waveform cut at the lane edge after a zoom. | [AU-VIEW] |
| Default range as an app setting | Audacity | "Meter dB range" in Interface Preferences. | [AU-PREF-IF] |
| Gain line, fades, meters move with zoom | No evidence in any app | Not found. | none |
| Saved with project | No evidence in any app | Not found. | none |

## D. Not found

- Audacity: Label Editor search or filter; user sort; multi-select; follow of play; a key for the Label Editor; a key for vertical zoom; gain line, fade, or meter behavior under zoom; display of a waveform that passes the lane edge; save of the zoom in the project file.
- Audition: Markers panel full column list; Markers panel search or filter; user sort; follow of play; Files panel details; range and steps of vertical zoom; scope of vertical zoom; reset of vertical zoom for the waveform; clipping display; save of the zoom; gain line and meter behavior.
- FCP: how to turn off the playhead follow in the index; user sort of the index; multi-select and delete in the index; amplitude scale and range of the waveform size; reset of the waveform size; save of the waveform size.
- Logic: search in the Marker List; rename in the Marker List (on the two pages read); follow of play; range, steps, scope, save, and clipping display of the Waveform Zoom.
- Hindenburg: a primary page was read in full for none of the items. Enter for a marker rename. Any amplitude zoom.
- Fetch failures: Adobe helpx pages (Access Denied); Hindenburg guide and knowledge-base pages (no text without scripts).

## Open question for a later probe

A check by hand in the real apps can settle: Audition (does Alt+= change only the amplitude?; does the Markers panel have a filter?), and Audacity (does Command-wheel on the scale zoom the amplitude by a fixed step?). No app ran in this session.

## Sources

Audacity manual (fetched 2026-11-11, "version created 2026-09-02"):

- [AU-LE] https://manual.audacityteam.org/man/labels_editor.html
- [AU-LT] https://manual.audacityteam.org/man/label_tracks.html
- [AU-LM] https://manual.audacityteam.org/man/edit_menu_labels.html
- [AU-VZ] https://manual.audacityteam.org/man/vertical_zooming.html
- [AU-TCP] https://manual.audacityteam.org/man/track_control_panel_and_vertical_scale.html
- [AU-WF] https://manual.audacityteam.org/man/audacity_waveform.html (the page shows the same recording in the linear view and in the dB view; the dB view "fills the display nicely")
- [AU-VIEW] https://manual.audacityteam.org/man/view_menu.html
- [AU-PREF-IF] https://manual.audacityteam.org/man/interface_preferences.html

Audacity source (fetched from the master branch on 2026-11-11; master was at commit 50535b233477ff0810976337bd02e5d9593348f6 when pinned afterwards, so the files may differ by later commits):

- [AU-SRC-VZH] https://raw.githubusercontent.com/audacity/audacity/master/au3/src/tracks/playabletrack/wavetrack/ui/WaveformVZoomHandle.cpp
- [AU-SRC-VRC] https://raw.githubusercontent.com/audacity/audacity/master/au3/src/tracks/playabletrack/wavetrack/ui/WaveformVRulerControls.cpp
- [AU-SRC-WS] https://raw.githubusercontent.com/audacity/audacity/master/au3/libraries/au3-wave-track-settings/WaveformSettings.cpp
- [AU-SRC-WSC] https://raw.githubusercontent.com/audacity/audacity/master/au3/src/prefs/WaveformScale.cpp

Adobe Audition:

- [AUD-REF] Adobe Audition CC 2015 reference (PDF, fetched from the Adobe archive; page numbers are those printed in the file): https://helpx.adobe.com/archive/en/audition/cc/2015/audition_reference.pdf . Used: "Working with markers" (Markers panel), "Change the vertical scale", "Zoom audio in the Editor panel", and the shortcut table.
- [AUD-MK-SEARCH] Search summary of https://helpx.adobe.com/audition/using/markers.html and https://helpx.adobe.com/audition/using/clip-markers-for-multitrack-in-audition.html (pages not fetched).
- [AUD-KEYS-SEARCH] Search summary of https://helpx.adobe.com/audition/desktop/keyboard-shortcuts/default-keyboard-shortcuts.html (page not fetched).
- [AUD-COMM-SEARCH] Not a primary source, not used for a claim: https://community.adobe.com/t5/audition-discussions/why-is-vertical-waveform-zoom-not-working-in-the-waveform-editor/m-p/9213276

Final Cut Pro (fetched):

- [FCP-IX] https://support.apple.com/guide/final-cut-pro/view-your-project-in-the-timeline-index-ver4e30596/mac
- [FCP-CA] https://support.apple.com/guide/final-cut-pro/adjust-timeline-clip-appearance-verb8e5d346/mac
- [FCP-KEYS] https://support.apple.com/guide/final-cut-pro/keyboard-shortcuts-ver90ba5929/mac
- [FCP-WF] https://support.apple.com/guide/final-cut-pro/audio-waveforms-verb97ccf3a/mac

Logic Pro:

- [LG-ML] https://support.apple.com/guide/logicpro/marker-list-interface-lgcp31f1cf25/mac (fetched)
- [LG-EM] https://support.apple.com/guide/logicpro/edit-markers-lgcp09f1e34f/mac (fetched)
- [LG-KEYS] https://support.apple.com/guide/logicpro/lgcpb99be9c5/mac ("Key commands for Main Window Tracks", fetched)
- [LG-ZOOM] https://support.apple.com/guide/logicpro/scroll-and-zoom-in-the-tracks-area-lgcpf7c0b924/mac (fetched)
- [LG-AMP-SEARCH] Search summary of https://support.apple.com/guide/logicpro/change-the-waveform-amplitude-scale-lgcp2158204f/mac (not fetched)
- [LG-EVT-SEARCH] Search summary of https://support.apple.com/guide/logicpro/event-list-interface-lgcp31f1a05a/mac and https://support.apple.com/guide/logicpro/project-audio-browser-interface-lgcpc788cc57/mac (not read)

Hindenburg PRO (search summaries only; the pages gave no text to a plain fetch):

- [HB-GUIDE-SEARCH] https://hindenburg.com/academy/guides/guides-hindenburg-pro/
- [HB-KEYS-SEARCH] https://hindenburg.com/academy/shortcuts/shortcuts-hindenburg-2-pro/
- [HB-WF-SEARCH] http://support.hindenburg.com/knowledgebase/articles/1958584-why-do-the-waveforms-look-the-way-they-do and https://hindenburg.com/data/functions/narrator-view-zoom-increase-track-height/
