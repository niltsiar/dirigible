# Ripple edit in Hindenburg, Final Cut Pro, Logic Pro, GarageBand, and three other editors

Date: 2026-10-04

This file adds to `docs/research/final-cut-pro.md` section 10, `edit-commands.md`, `mouse-edits.md`, `timeline-playback.md` section 4, and `logic-garageband-update.md`. It does not repeat their facts. It answers the seven questions of the ripple-edit run.

Source grades. Each claim has a tag. The tag tells the grade:

- **P**: a primary page of the vendor (Apple, Avid, Cockos, Hindenburg).
- **L**: local evidence from an installed app bundle, read only. Logic Pro 12.3.1, GarageBand 10.4.14, Final Cut Pro 12.3. A string in a strings file does not prove that the command is in the UI of that app.
- **S**: a secondary source (a key list, a blog, a book).
- **U**: a user post on a forum. **H** marks a reply from the vendor staff on a forum.

"(unconfirmed)" means that no source answers. A sentence that starts with "Inference:" is our reading of the sources. No probe and no on-screen check ran in this research, because a bench loop runs on this Mac.

The Hindenburg shortcuts page shows Windows keys only [HSC]. This file maps Ctrl to Cmd for macOS. The repo videos give Shift-Cmd-drag for the shuffle trim on macOS (edit-commands.md section 3).

## Key new facts

1. **Hindenburg ripples a trim with the keys, not with the mouse.** Q "Trims the beginning of the region to the playhead". Shift-Q "Top Slip" trims the same way "without moving the following regions". W and Shift-W do the same at the end [HSC] (P). Inference: Q and W ripple the later regions; Shift-Q and Shift-W do not.
2. **Hindenburg Cut ripples the whole track.** "Region Cut" (Shift-Cmd-X, mapped from Shift-Ctrl-X): "The Cut edit will only affect the region - not the entire track" [HSC] (P). Inference: plain Cut changes the entire track, so it moves the later regions of the track.
3. **Final Cut Pro roll is the Trim tool (T), not R.** R selects the Range Selection tool (final-cut-pro.md section 3). A roll is the Trim tool and a click on the center of the edit point [FRO] (P).
4. **Logic Pro ripples a resize only through the Drag menu.** Shuffle L moves the later regions when you resize the right edge. Shuffle R moves the earlier regions when you resize the left edge [LDM] (P). No modifier key gives a ripple resize [LPT] (P).

## 1. The ripple trim gesture and the free modifiers

### Hindenburg PRO

- **Mouse trim.** "Drag Trim Handle" [HSC] (P). No source documents a modifier that ripples an edge drag (unconfirmed).
- **Shuffle trim.** "shift + Ctrl Mouse": "Move the edit point without breaking the edit apart" [HSC] (P). The page names it "Shuffle Trim (Slip Edit)" [HSC]. Inference: it is a roll of two touching regions. No later region moves. No source shows it on a region with a gap after it (unconfirmed).
- **Keyboard ripple trim.** Q and W ripple. Shift-Q and Shift-W do not ripple [HSC] (P). See key new fact 1.
- **Taken modifiers at an edge.** Shift-Cmd (shuffle trim) [HSC] (P). Option-drag and Cmd-drag on a region send it to the Clipboard panel (edit-commands.md section 2). Inference: the same modifiers can also act at the edge. No source says so (unconfirmed).
- **Free modifiers.** Option, Control, and Shift alone at the edge are not documented (unconfirmed).

### Final Cut Pro 12.3

- **Default.** "The default type of trim in Final Cut Pro is a ripple edit". "Any clips to the right of the edit point are rippled accordingly" [FTR] (P).
- **No ripple.** Press P for the Position tool, or hold P for a temporary switch [FAR] (P). With the Position tool, a moved clip "overwrites any clips at the new position. A gap clip fills in the vacated part of the timeline" [FAR] (P). "When you trim clips, it leaves a gap" [LJ] (S, Larry Jordan, Peachpit 2023).
- **Roll.** Choose the Trim tool (T), or hold T. Click the center of the edit point and drag. "No clips move in the timeline as a result" [FRO] (P).
- **Taken modifiers.** The Grave Accent (`) overrides the connections (final-cut-pro.md section 1). Option turns the two-up display off or switches its side while you trim [F2U] (P). Shift-X extends the edit to the playhead [FTR] (P).
- **Free modifiers.** No source lists a modifier for an edge drag with the Select tool (unconfirmed).

### Logic Pro 12.3

- **Shuffle L.** "Resize: When you resize the right edge of a region, the regions that follow move by the change in length." **Shuffle R**: "When you resize the left edge of a region, the preceding regions move by the change in length" [LDM] (P). The mode is a Drag pop-up menu in the Tracks area menu bar. It is not a modifier [LDM] (P).
- **Same track only.** Logic 9 said: "the other regions on the track are moved to accommodate the new length" [L9DM] (P, old version).
- **Taken modifiers at an edge.** Option changes the Resize tool to the Stretch tool [LPT] (P). Option-Shift resizes the selected regions "to the same absolute length" [LRS] (P). Control and Control-Shift give finer snap steps for a move [LMV] [LPT] (P). Inference: they act the same on a resize. Shift restricts a drag to the first direction [LPT] (P). Command gives the Command-click tool [LAT] (P, via logic-garageband-update.md).
- **Free modifiers.** None. Inference: each modifier at an edge already has a meaning.
- **Other ripple names.** The Logic strings file has "Shuffle Delete" and "Shuffle Delete Marqueed Area" [LLOC] (L). The guide does not document them (unconfirmed).

### GarageBand 10.4.14

- No drag mode and no ripple resize are documented (unconfirmed). The guide has "Delete and Move" for regions [GDR] (P). The strings file has "Shuffle Delete" [GLOC] (L), but no guide page shows it in the UI (unconfirmed).
- A move or a delete of an arrangement marker ripples: "the sections to the right move left to fill the deleted section" [GAM] (P).

### Adobe Audition (context)

- The Multitrack Editor has Edit > Ripple Delete with a submenu, for example "Time Selection in All Tracks" [AUF1] (U, community expert, 2020) [AUF2] (U). No primary page loaded (Adobe answered 403). No source documents a ripple trim modifier (unconfirmed).

### Pro Tools (context)

- Shuffle is an Edit mode, not a modifier. F1 or Option-1 selects it [PTS] (P). "When using any of the Trim tools in Shuffle mode, changing a clip's start or end point automatically moves any subsequent clips as necessary" [PT2] (P).
- The movement is "constrained by other clips". A silence between clips stays [PT2] (P).
- Shuffle Lock: Cmd-click the Shuffle button. It disables "all key commands switches for Shuffle mode" [PT1] (P).

### REAPER 7.81 (context)

- Ripple editing is a global mode: off, per track, or all tracks. Alt-P (Option-P on macOS) cycles the three modes [RG p. 139-140] (P).
- "Ripple edit per track: ... ripple editing will be applied when you are editing the currently selected track(s) but not to any other." "Ripple edit all tracks: ... any editing you do to any of the items on any track will also be applied to all other tracks" [RG p. 139] (P).
- The right-click menu of the ripple button has an option to apply ripple "When editing media item edges" [RG p. 140] (P).
- Mouse modifiers are user-defined per context, also "Media item edge (left drag and double-click)". The modifiers can apply "any of the three ripple editing states" [RG p. 140, 149] (P). The default modifiers for the edge are in an image, not in text (unconfirmed).

## 2. Visual feedback during a ripple trim

| App | What it draws | Source |
|---|---|---|
| Final Cut Pro | The pointer changes to a trim icon. The icon shows which side the trim changes. Timecode fields above the edit point show the clip duration and the amount of the move. The clip edge turns red at the end of the media. The later clips ripple. | [FTR] (P) |
| Final Cut Pro | Option-U turns on the two-up display in the viewer: the end of the left clip and the start of the right clip. It shows for ripple, roll, slip, and slide edits. | [F2U] (P) |
| Final Cut Pro | A drag of a clip shows "an outline of your selection at the new position". The ripple happens "When you release the clip". | [FAR] (P) |
| Logic Pro | A help tag below the pointer, "for as long as the mouse button is held down". It shows the name of the operation, the position, the region name, the track number, and the length. A setting adds bars and beats and time. | [L9HT] (P, old version) [LGV] (P) |
| Logic Pro | The Resize pointer at the lower-left or lower-right edge. The Junction pointer at the upper edge between two touching regions. | [LRS] (P) |
| Hindenburg, GarageBand, Pro Tools, REAPER, Audition | No source describes the feedback of a ripple trim. | (unconfirmed) |

- Final Cut Pro: no source says if the later clips move live during an edge drag or at the release. Inference from [FTR]: they move live, because the page says "As you drag, the clip shortens or lengthens" and then "Any clips to the right ... are rippled".
- Logic Pro Shuffle L: no source says if the later regions move live (unconfirmed).
- No source shows a dimmed overlay of the removed span in any app (unconfirmed).

## 3. Context menus

- **Hindenburg region menu.** The list in edit-commands.md section 5 stays the best source: Undo, Cut (Cmd-X), Copy, Paste, Replace, Insert (Cmd-I), Clear (Delete), Split, Rename, Merge, Import, Export Selection, Play Selection, Rehearse Clip, Properties [V-clear]. Cut and Insert are the ripple items. They are in the edit group, before Clear. No new source changes this list.
- **Hindenburg empty lane menu.** No source (unconfirmed). The track header menu has Add Track and Delete Track (edit-commands.md section 9).
- **Final Cut Pro clip menu.** No primary source lists it (unconfirmed). "Replace with Gap" is in the Edit menu with Shift-Delete [FRM] (P). The local app has the string only in `MainMenu.nib` and in the command name strings, not in a separate context menu file [FCPL] (L). Inference: the timeline context menu is built in code, so only an on-screen check can give its order.
- **Logic Pro region menu.** No primary source lists the items or their order (unconfirmed). The guide shows a "Name and Color" submenu in it [LCOL] (P). The ripple commands are in the main Edit menu: Edit > Delete and Move [LDR], Edit > Cut/Insert Time > Cut Section Between Locators and Insert Silence Between Locators [LGP] (P).
- **GarageBand region menu.** "Control-click the region, then choose Delete from the shortcut menu" [GDR] (P). "Delete and Move" is in the Edit menu [GDR] (P). The full list is unconfirmed.
- **REAPER.** A right-click on a time selection gives "Remove contents of selection (moving later items)" [RG p. 219] (P). "Trim items to selected area" is in the item menu. With ripple on, "the area that is trimmed will also be removed from the timeline" [RG p. 140] (P).
- **Audition.** A right-click on a time selection gives Ripple Delete [AUF1] (U).

## 4. Key bindings

| App | Command | Key | Source |
|---|---|---|---|
| Logic Pro | Delete and Move | Not in [LKT] or [LKG] (P), and not in [LPKC] (S); one secondary excerpt says Shift-Delete [HYP] (S); unconfirmed |
| Logic Pro | Snip: Cut Section Between Locators (Global) | Control-Command-X | [LPKC] (S, list for 10.4.1) |
| Logic Pro | Insert Silence Between Locators (Global) | Control-Command-Z | [LPKC] (S) |
| Logic Pro | Splice: Insert Snipped Section at Playhead (Global) | Control-Command-V | [LPKC] (S) |
| Logic Pro | Cut Sections of Selected Arrangement Markers | Option-Command-Delete | [LPKC] (S) |
| Logic Pro | Shuffle Left, Shuffle Right (close gaps) | Option-[, Option-] | [LKT] (P) |
| Logic Pro | The "(Selection)" variants of Cut Section and Insert Silence | Key command only, no default key | [LGP] (P) for the command; key unconfirmed |
| GarageBand | Delete and Move | No key in the shortcut page | [GKS] [GDR] (P) |
| Hindenburg | Cut (closes the gap) | Cmd-X | [HM p. 28] (P) |
| Hindenburg | Insert (pushes later regions) | Cmd-I | [HM p. 30] (P) |
| Hindenburg | Clear (keeps the gap) | Backspace in PRO 2 | [HSC] (P); timeline-playback.md section 4 |
| Hindenburg | Region Cut (no ripple) | Shift-Cmd-X | [HSC] (P), mapped from Windows |
| Hindenburg | Insert Silence, Delete Silence | Cmd-Right, Cmd-Left | [HM p. 37, 97] (P) [HSC] (P) |
| Hindenburg | Insert Special (phone interviews) | Shift-Cmd-Right | [HSC] (P), mapped from Windows |
| Hindenburg | Top, Tail (ripple trim to the playhead) | Q, W | [HSC] (P) |
| Hindenburg | Top Slip, Tail Slip (no ripple) | Shift-Q, Shift-W | [HSC] (P) |
| Final Cut Pro | Delete (ripple) | Delete | [FRM] [FKS] (P) |
| Final Cut Pro | Replace with Gap | Shift-Delete | [FRM] [FKS] (P) |
| Final Cut Pro | Delete Selection Only (connected clips go to the gap clip) | Option-Command-Delete | [FKS] (P) |
| Audition | Ripple Delete submenu | Secondary sources disagree: Shift-Backspace and others, or Ctrl-Alt-Delete | [AUK] [IEP] (S); unconfirmed |
| REAPER | Delete part of the selected item | Ctrl-Delete [RG p. 124] (P). Inference from [RG p. 139]: it ripples only when a ripple mode is on | [RG p. 124, 139] (P) |
| REAPER | Remove contents of selection (moving later items) | Context menu; default key unconfirmed | [RG p. 219] (P) |
| Pro Tools | Cut or Delete in Shuffle mode (closes the gap) | Cmd-X, or Delete in Shuffle mode | [TRM] (S, Transom 2015) |

- The Logic Pro strings file has these names: "Cut Section Between Locators (Global)", "(Selection)", "Delete Section Between Locators (Global)", "Insert Silence Between Locators (Global)", "(Selection)", "Insert Silence within Cycle" [LLOC] (L). Inference: "Delete Section" removes the range without the Clipboard. The guide does not document it (unconfirmed).

## 5. Markers in a ripple

- **Logic Pro, all regions.** Cut Section moves "all regions (and bar changes, tempo changes, and global score symbols)" after the range to the left [LGP] (P). The main text does not name markers. A tip says: "To guarantee all tracks are shifted, including tempo, time signature changes, and markers, make sure everything is selected (using Command-A or Shift-I) before cutting and inserting" [LGP] (P).
- **Logic Pro, selected regions only.** "you are asked if you want to move global events such as bar changes, tempo changes, and score symbols. This global edit is performed on all regions, when used" [LGP] (P). Inference: the user chooses at the edit if the global events move. No source says if markers belong to these global events (unconfirmed).
- **GarageBand.** A move of an arrangement marker moves "the markers on every track in the section, and the automation points" [GAM] (P).
- **Hindenburg.** Build 2752 "Fixed cases where using Insert could incorrectly affect existing markers" [R2752] (P). Staff, 2018: "It is possible to set Cue Point in the audio itself. When setting Cue Points the markers will follow the edits" [UV-sticky] (H). The same thread says that markers stay behind when the user moves regions with Select to End [UV-sticky] (U). A user, 2020: "Move all audio (= all tracks) at the same time, e.g with Ctrl+X or Ctrl+left/right arrow. This will move chapter markers along" [UV-lock] (U). Inference: Hindenburg moves a marker only when the edit spans all tracks. A cue point is part of the region and always moves with it. No primary source confirms the all-tracks rule (unconfirmed).
- **REAPER.** "In this mode, markers and automation are locked to the items that they relate to, so as you move items the associated markers and automation move too" [RG p. 140] (P). Inference: "this mode" is ripple all tracks, because the sentence follows the all-tracks text and the per-track mode leaves other tracks in place. Options add "Ripple edit all affects tempo map" and an option for envelopes on all tracks [RG p. 140] (P).
- **Final Cut Pro.** Markers ride clips (final-cut-pro.md section 5). No new fact.
- **Audition.** The markers move with a Ripple Delete when the setting "Lock markers and metadata to the timeline" is off [AUC] (U). Unconfirmed from Adobe.
- **Pro Tools.** No source (unconfirmed).

## 6. Scope: which tracks ripple

- **Hindenburg.** Cut acts on the selection. A selection spans the tracks that the user adds with Cmd-click or Shift-click (timeline-playback.md section 3). "All following regions on the track will subsequently move to the left. If you are working on a multi track session, be ware of the sync between tracks" [HW p. 12] (P). Region Cut limits the edit to the region [HSC] (P). Inference: Cut ripples only the tracks in the selection, never an unselected track. Insert Special says: "when tracks are linked the insert will be after in on one track and after out on the other" [HSC] (P). No other source documents linked tracks (unconfirmed).
- **Logic Pro.** The toolbar buttons and the menu commands act on "all regions that fall between the locators, regardless of which regions in the area are selected". The "(Selection)" key commands act only on the selected regions [LGP] (P). For Insert Silence: "If no selection is made, all regions that fall between the locators are affected" [LGP] (P). Shuffle L and Shuffle R act on one track [LDM] [L9DM] (P). Delete and Move moves "all regions that follow" [LDR] (P). Inference: on the same track, as in GarageBand: "the regions that follow in the track" [GDR] (P).
- **Final Cut Pro.** The ripple acts on the primary storyline. Connected clips ride with their primary clip (final-cut-pro.md section 10).
- **REAPER.** A global mode: per track (the selected tracks) or all tracks [RG p. 139] (P). Locked items have four rules: interrupt the ripple, interrupt it per track, stay unaffected, or ignore the lock [RG, Editing Behavior] (P).
- **Audition.** The Ripple Delete submenu chooses the scope, for example the selected clips or "Time Selection in All Tracks" [AUF1] (U).
- **Pro Tools.** Shuffle mode acts on the track of the edit [PT2] (P). Inference: an edit on several selected tracks ripples each of them.

## 7. Playhead and selection after a ripple delete or cut

- **Logic Pro.** The key command "Delete and Select Next Region/Event" deletes the selection, and "the next region is automatically selected" [LDR] (P). No source says where the playhead goes after Delete and Move or Cut Section (unconfirmed). Inference: the playhead does not move, because no page says that it moves.
- **Final Cut Pro.** No source (unconfirmed).
- **Hindenburg.** No source (unconfirmed). After Paste, the pasted region is selected (edit-commands.md section 6). This says nothing about Cut.
- **GarageBand, REAPER, Pro Tools, Audition.** No source (unconfirmed). REAPER says "Press Esc to clear the time selection" after a crop [RG p. 219] (P). Inference: the time selection stays after the edit.

## Open questions for the plan

1. The most common gesture was not checked in any app: a right-edge drag that shortens one clip on one track of a multitrack session. Check it on screen after the bench, in Final Cut Pro 12.3, and in Logic Pro 12.3.1 with Drag set to Shuffle L. Record if the later clips move live, and if the other tracks move.
2. On-screen checks for the installed apps, after the bench:
   - The order of the clip or region context menu in Final Cut Pro, Logic Pro, and GarageBand, and the menu of an empty lane area.
   - The playhead and the selection after Logic Delete and Move, Logic Cut Section Between Locators, GarageBand Delete and Move, and Final Cut Pro Delete.
   - The Logic dialog for "Cut Section Between Locators (Selection)": its text, and if markers move with "yes".
   - The default key of Logic "Delete and Move" in the Key Commands window (Option-K).
3. Hindenburg (not installed): Cut on one track and Cut on all tracks, with one marker inside the range and one after it. Record the marker frames after each edit. Also check if Q and W ripple only the selected track.
4. No app in this file has a modifier for a ripple edge drag that a Hindenburg user knows. Hindenburg ripples a trim with Q and W. Inference: a Dirigible modifier for a ripple trim is our own choice, not a copy. The plan picks it.

## Sources

Hindenburg:

- [HSC] Hindenburg Pro Shortcuts (Windows keys): https://hindenburg.com/academy/shortcuts/shortcuts-hindenburg-2-pro/ (read with WebFetch on 2026-10-04; curl got a server error in the grid)
- [HM] Hindenburg Journalist 1.21 user guide for macOS, pages 28 to 30, 37, 97 (text read with PDFKit on 2026-10-04): https://www.willyurman.com/teaching/handouts/Hindenburg_Journalist.pdf
- [HW] Hindenburg Journalist guide for Windows, pages 12 to 14: http://hindenburgsystems.com/wordpress/wp-content/uploads/2010/07/Hindenburg-Journalist-Guide-Windows.pdf
- [R2752] https://hindenburg.com/release-notes-hindenburg-pro_version-2/pro-v2_05-build-2752/
- [UV-sticky] 'Sticky' markers (2018): https://hindenburg.uservoice.com/forums/224350-general/suggestions/35917498--sticky-markers
- [UV-lock] Ability to lock chapter markers to audio (2020): https://hindenburg.uservoice.com/forums/224350-general/suggestions/41213986-ability-to-lock-chapter-markers-to-audio
- [V-clear] https://www.youtube.com/watch?v=eaALdtdc1bw (frames, see `docs/research/edit-commands.md`)
- [TRM] Transom, Pro Tools vs. Hindenburg Macintosh key commands (2015): https://transom.org/wp-content/uploads/2015/10/PT_Hindy_Commands_Mac.pdf

Final Cut Pro (https://support.apple.com/guide/final-cut-pro/<page>/mac):

- [FTR] extend-or-shorten-clips-ver9847ec25
- [FRO] make-roll-edits-ver1632d9ae
- [FAR] arrange-clips-in-the-timeline-verc147f195
- [F2U] show-a-two-up-display-in-the-viewer-ver3363b235
- [FRM] remove-clips-from-projects-verc5d34129
- [FKS] keyboard-shortcuts-ver90ba5929
- [LJ] Larry Jordan, Final Cut Pro Power Tips, Peachpit 2023, "Editing Tools": https://www.peachpit.com/articles/article.aspx?p=3150365&seqNum=5
- [FCPL] Local: `grep` for "Replace with Gap" in `/Applications/Final Cut Pro.app` (version 12.3) found `Resources/Base.lproj/MainMenu.nib`, `Resources/en.lproj/NSProCommandNames.strings`, and `Flexo.framework/.../FFLocalizable.strings` only.

Logic Pro and GarageBand (https://support.apple.com/guide/logicpro/<page>/mac and https://support.apple.com/guide/garageband/<page>/mac, version 12.3 and 10.4.14):

- [LDM] control-positioning-with-drag-modes-lgcpf7c0a2ec
- [LGP] add-or-remove-gaps-lgcp21e2cb21
- [LDR] delete-regions-lgcpf7c0bd98
- [LRS] resize-regions-lgcpf7c0c964
- [LMV] move-regions-lgcpf7c0d489
- [LPT] tracks-area-lgcpea796663 (pointer shortcuts)
- [LKT] main-window-tracks-and-various-editors-lgcpe8314fe2
- [LKG] global-commands-lgcp02bf31b6
- [LAT] assign-tools-lgcp5b365bf4
- [LGV] general-settings-lgcp9793a910
- [LCOL] change-the-color-of-regions-lgcpf7c0db8c (read through a search excerpt)
- [L9DM] Logic Pro 9.1.6 manual, Using Drag Modes: https://help.apple.com/logicpro/mac/9.1.6/en/logicpro/usermanual/chapter_13_section_3.html
- [L9HT] Logic Pro 9.1.6 manual, Working with Help Tags: https://help.apple.com/logicpro/mac/9.1.6/en/logicpro/usermanual/chapter_8_section_6.html
- [LLOC] Local: `Logic.framework/Versions/A/Resources/en.lproj/Localizable.strings` in Logic Pro 12.3.1, read with `plutil`.
- [LPKC] Logic Pro X 10.4.1 key commands list: http://www.logicprokeycommands.com/logic-pro-x-key-commands-10-4-1/
- [HYP] Hyperbits, Logic Pro shortcuts (search excerpt only): https://hyperbits.com/logic-pro-shortcuts/
- [GDR] Delete regions in GarageBand on Mac: https://support.apple.com/en-hk/guide/garageband/gbnd799e606a/mac
- [GAM] Edit arrangement markers in GarageBand on Mac: https://support.apple.com/guide/garageband/gbnd704aca5e/mac
- [GKS] main-window-shortcuts-gbnd58362a62
- [GLOC] Local: `/Applications/GarageBand.app/Contents/Resources/en.lproj/Localizable.strings` in GarageBand 10.4.14, read with `plutil`.

Pro Tools:

- [PT1] Pro Tools First Help 12.0, Shuffle Lock: https://apps.avid.com/proToolsFirstHelp/version12.0/enu/Pro%20Tools%20First%20Help/ed2.ModesTools.24.04.html
- [PT2] Pro Tools First Help 12.0, Shuffle Mode: https://apps.avid.com/proToolsFirstHelp/version12.0/enu/Pro%20Tools%20First%20Help/ed2.ModesTools.24.03.html
- [PTS] Pro Tools Shortcuts Guide 12.8.2: https://resources.avid.com/SupportFiles/PT/Pro_Tools_Shortcuts_12.8.2.pdf

REAPER:

- [RG] Up and Running: A REAPER User Guide v7.81, section 7.20 (pages 139 to 140), section 12.3 (page 219), page 124, page 149, and the Editing Behavior preferences: https://www.reaper.fm/userguide/ReaperUserGuide781c.pdf

Adobe Audition (helpx.adobe.com answered 403 to the fetch tools):

- [AUF1] Cut and delete gap in all tracks in Audition (community expert, 2020): https://community.adobe.com/questions-544/cut-and-delete-gap-in-all-tracks-in-audition-159325
- [AUF2] Ripple delete across tracks query: https://community.adobe.com/questions-544/ripple-delete-across-tracks-query-162546 (search excerpt only)
- [AUC] Ripple deleting and markers, Creative COW: https://creativecow.net/forums/thread/ripple-deleting-and-markers/
- [AUK] Search excerpt that gives Shift-Backspace, Alt-Backspace, and Ctrl-Shift-Backspace, source page not identified; treat as unconfirmed.
- [IEP] I Edit Podcasts, keyboard shortcuts (2019, updated 2022): https://www.ieditpodcasts.com/post/best-keyboard-shortcuts-for-editing-your-podcast
