# Edit commands in Hindenburg PRO 2

Date: 2026-09-25

This document records how Hindenburg edits regions, tracks, and markers with the mouse, the keys, and the menus. It also records the Apple facts for the pasteboard, the Finder, and menu keys. It adds to `docs/research/timeline-playback.md` and `docs/research/timeline-view.md` and does not repeat them. The key table is in `docs/research/podcast-features.md`.

The source tags [HM], [HW], [Rnnnn], and [V-*] have the same meaning as in `docs/research/timeline-playback.md`. [HM] is the 1.21 manual for macOS. [HW] is the Windows guide. Both are for version 1. A page number is the page of the manual.

This document also uses still frames of the official videos, as `docs/research/timeline-view.md` does. A sentence that starts with "The frames of [V-x] show" reports what the frames show. The videos have no captions. A claim that no primary source confirms has the mark "(unconfirmed)". A sentence that starts with "Inference:" is our reading of the sources.

## 1. Mouse on a region

- **Cursor zones.** "The cursor will change depending on where you are on the region." The zones are Drag Selection, Move Region, Level/gain, Trim, and Fade [HM p. 24].
- **Move zone.** "The cursor becomes an 'Arrow' when moved to the middle section of the region." While the user drags, "the cursor will turn to a fist" [HM p. 25]. The Windows guide says the same: "Click the mouse in the middle of the Region and it turns into a FIst" [HW p. 16].
- **Selection zone.** The I-beam is on the lower part of the region [HM p. 26] [V-drag]. This is known.
- **Gain zone.** "Move the mouse to the top of the Region and it turns into a Gain cursor" [HW p. 16].
- **Trim zone.** "Move the mouse to the either end of the Region and it turns into a Trim cursor" [HW p. 16]. The frames of [V-trim] show the trim cursor near the lower end of the right edge.
- **Fade zone.** "Fade handles are at all four corners" [HW p. 16].
- Inference: from top to bottom, a region has a gain line, a middle move zone, and a lower selection zone. The ends trim. The corners fade.
- **Cursor over a marker.** A 2015 user post says that the cursor changes over a marker line, so the user "cannot begin a selection there" [UV-cursor].
- **Click selects.** A click on a region selects it. The region turns orange. A click on another region clears the first selection [V-selregion] [HW p. 16].
- **Click selects the track.** The frames of [V-selregion] and [V-movetrack] show that the track of the clicked region becomes the selected track. Its name bar turns blue.
- **Click and the playhead.** The frames of [V-selregion] show clicks on three regions. The counter stays at 01:32. The frames of [V-split] show a click on a region right of the playhead. The counter stays at 17:53. Inference: a click on a region does not move the playhead.
- **Cmd-Option-click** on a region selects all regions to the end, on all tracks. Build 2550 gives this tip "When moving regions around on multiple tracks" [R2550].

## 2. Move a region

- **Drag.** Drag the middle of the region to move it [HM p. 25] [HW p. 16].
- **Drop on other regions.** No source says if a dropped region overwrites, pushes, or refuses the regions under it (unconfirmed). Paste places audio "ON TOP of existing audio" [HM p. 29]. Inference: a drop can also overlap. This needs a hardware check in PRO 2.
- **To another track.** Cmd-Up Arrow and Cmd-Down Arrow move the selected region to the track above or below [V-movetrack]. A caption says: "Easily Move Regions While Retaining Your Timing" [V-movetrack]. No source says if a mouse drag can also change the track (unconfirmed).
- **Grid and snap.** View > Grid > Fine Grid helps to "Align regions to the timeline accurately" [V-finegrid]. No source says if a drag snaps to other region edges (unconfirmed). Shift-Cmd-Arrow snaps a region to the nearest event (known) [V-snap].
- **Copy with a modifier.** Option-drag copies a selection from the workspace to the Clipboard panel. Cmd-drag moves it [HM p. 57] [V-clipdrag] [V-clipsel]. Option-drag of a clip from the Clipboard panel to the workspace copies it [HM p. 57] [HW p. 23]. No source says if Option-drag inside the workspace duplicates a region (unconfirmed). Duplicate (Cmd-D) pastes the selection "repeatedly after itself" [HW p. 13].
- **Constraint.** No source documents a modifier that locks a drag to time or to track (unconfirmed).
- **Groups.** Cmd-G groups regions "to move them around as a group" [V-group].
- **Undo name.** The frames of [V-clear] show the first item of the region context menu: "Undo Move: Drake introduction, ...". Inference: the undo item names the command and the region.

## 3. Trim by edge drag

- "Drag the Region ends" [HW p. 16]. "Drag the Trim Handle to create a trimmed section on a region" [V-trim].
- The frames of [V-trim] show the right edge dragged out, then in, then out again. At the end, the edge is on the playhead line. No source says if the edge snaps to the playhead (unconfirmed).
- **Past the file length.** No source says if a trim can grow a region past the end of its audio file (unconfirmed). Inference: the region shows audio from its file, so it cannot grow past the file.
- **At a neighbor.** No source says what happens when a trim reaches the next region (unconfirmed).
- **Shuffle trim.** Shift-Cmd-drag moves "the edit point without breaking the edit apart" [V-shuffle]. Inference: this trims two touching regions at the same time.
- **Slide.** Shift-Cmd-drag also slides the audio inside a region [V-slide]. Inference: the zone of the drag chooses between the two commands (unconfirmed).

## 4. Nudge

- The video title is "How to move a region by a millisecond". The description says: "Moves the region in millisecond increments" [V-nudge]. The Windows guide calls Ctrl-Left and Ctrl-Right "Move (nudge)" [HW p. 16].
- The frames of [V-nudge] show a move of approximately 2 to 3 seconds. The ruler labels are 5 seconds apart, at approximately 6.6 pixels per second. Inference: the key auto-repeats, or the step is larger than 1 ms. The step is unconfirmed.
- **Selected regions only.** The frames of [V-nudge] show two selected regions move by the same amount. An unselected region on the same track stays. Inference: nudge moves all selected regions and nothing else.

## 5. Delete a region

- The PRO 2 video "How to delete a whole region" uses Clear. The description says it is for "removing entire blocks of audio". The key is Backspace [V-clear].
- The frames of [V-clear] show a right-click on a selected region, then Clear. The region goes away. The gap stays. Then the user makes an in/out range and presses Delete. The range goes away and the gap stays.
- The region context menu in the frames has these items and keys: Undo (Cmd-Z), Cut (Cmd-X), Copy (Cmd-C), Paste (Cmd-V), Replace (Shift-Cmd-V), Insert (Cmd-I), Clear (Delete), Split (Cmd-B), Rename (Return), Merge (Shift-Cmd-M), Import (Cmd-T), Export Selection (Shift-Cmd-E), Play Selection (Shift-Space), Rehearse Clip (Control-Shift-Space), Properties (Option-Return) [V-clear].
- **Several regions.** Cmd-click selects several regions "for editing. Cut, Copy & Paste or move the regions around" [V-cmdclick]. No source shows Clear on several regions (unconfirmed). Inference: Clear removes every selected region.

## 6. Copy, Cut, Paste

- **Program memory.** Copy "will add the selection to the program memory" [V-copy].
- **Target track.** The frames of [V-paste] show a copy from the track "Speak". Then the user clicks the track "Interview" and moves the playhead. Cmd-V puts the audio on "Interview" at the playhead. Inference: Paste targets the selected track, at the playhead.
- **After Paste.** The frames of [V-copy] and [V-paste] show the pasted region selected (orange). The source region is not selected.
- **Several tracks.** No source says what Paste does with a copy from several tracks (unconfirmed).
- **Paste from another app.** In 1.21, the user can press Cmd-C on a file in Finder or iTunes and Cmd-V in Hindenburg. This imports the file [HM p. 15]. Build 2572 "Improved functionality when dragging and dropping from other applications" [R2572].
- **Copy to another app.** No source says if Cmd-C in the workspace puts audio on the macOS pasteboard (unconfirmed). Inference: "program memory" [V-copy] is an internal buffer.
- **The Clipboard panel.** The Clipboard is a panel, not the system pasteboard. It "is used for organizing the audio material in your session" (View > Clipboard, Option-Cmd-C) [V-clip] [HM p. 11]. It has groups and, in PRO 2, sub-groups and search [V-clipboard2].
- **To the panel.** Cmd-drag moves regions or a selection to the panel [V-clipdrag] [V-clipsel]. Option-Cmd-(group number) moves regions to a group [V-clipmove]. No source says if Cmd-C also adds the audio to the panel (unconfirmed).
- **From the panel.** Cmd-Return pastes a clip into the workspace. Shift-Return inserts it [V-clippaste] [V-clipinsert].
- **Copy as Text.** The Clipboard video has a chapter "Copy as Text" [V-clipboard2]. Inference: this puts the clip transcript on the system pasteboard as text (unconfirmed).

## 7. Split

- Split breaks the region at the playhead. With in and out points, it splits at both [HM p. 28] [HW p. 13]. This is known.
- **Which tracks.** The frames of [V-split] show a session with regions on one track only. No source says if Split with no selected track acts on all tracks (unconfirmed).
- Shift-Cmd-B splits and selects the right side [R2544]. This is known.

## 8. Markers and chapters

- **Default name.** The frames of [V-markers] and [V-mrename] show new markers named "Marker 3", "Marker 4", and so on. The number is the marker number.
- **Chapter name.** The frames of [V-chapter] show a new chapter with the name "Marker 26". A text field opens on the ruler at once, with the name selected. The user types the new name there. Inference: chapters and markers share one number sequence.
- **Chapter look.** The frames of [V-chapter] show a chapter as a yellow dot on the ruler, with its name to the right.
- **Rename a marker.** The description of [V-mrename] gives Shift-Return. The caption in its frames says "Return (enter)". The frames show the rename in the Markers list: the name cell becomes a text field. The new name then shows on the ruler [V-mrename]. The 1.21 manual gives Return [HM p. 59]. The Windows guide gives Return to rename and Shift-Return to renumber [HW p. 26].
- **Markers list.** The Markers view (Option-Cmd-M) is a window with one row per marker: number, name, time [V-markers]. With a selection, rows "1 In" and "2 Out" show first [V-mrename].
- **Chapters list.** The View menu has separate items for Markers and Chapters [V-markers]. The Chapters view is Option-Cmd-H [V-chapters]. Inference: markers and chapters are two lists.
- **Delete a marker.** Select the row in the Markers list and press Delete [V-mdelete] [HW p. 26]. The right-click menu of the ruler also has Delete Marker [V-marker].
- **Move a marker by drag.** No source shows a drag of a marker on the ruler (unconfirmed). In and out points drag on the ruler (known).
- **Next and previous.** Page Up, Page Down, Tab, and Shift-Tab jump to the next "splice or marker" (known) [V-event].
- **Insert.** Build 2752 "Fixed cases where using Insert could incorrectly affect existing markers" [R2752]. Inference: Insert moves the markers after the insert point.

## 9. Delete a track

- **Command.** Right-click the track header. The menu has Add Track and Delete Track [V-deltrack] [HM p. 13] [HW p. 20]. File > Properties also has a Minus button that deletes tracks [HW p. 30].
- **Key.** No source gives a key (unconfirmed).
- **Confirmation.** The frames of [V-deltrack] show an alert: "You are about to delete a track that contains regions. Do you want to continue?" The buttons are No and Yes. Yes is the default.
- **Regions.** After Yes, the track and its regions go away [V-deltrack]. Inference: the alert shows only when the track has regions.

## 10. Show the file in Finder

- No source documents a "Show in Finder" or "Reveal in Finder" command (unconfirmed).
- **Region Properties** (Option-Return) shows Name, File, Resolution, Length, Start Offset, Original, and Date [V-props]. The File field shows a short path, for example ".../Favorites/CaceresE3tracking_001.wav", with a "..." button. The Original field shows the full path of the imported file [V-props].
- A right-click on a blank region lets the user point it to the correct file [KB-blank]. Inference: the "..." button is this relink command (unconfirmed).

## 11. Marquee selection

- Shift-drag draws a marquee [V-marquee]. The frames show the drag start in an empty area of the lowest track. The rectangle goes up and right across three tracks. All regions in the rectangle turn orange. Regions outside it on the same tracks stay blue. Esc clears the selection [V-marquee].
- No source says if a region must be fully inside the rectangle or only touch it (unconfirmed).

## 12. Region selection and range selection

- "Select a region to edit the entire region. Add fades or any edit function, like Cut, Copy & Paste" [V-selregion].
- Cut, Copy, and Clear act on a selected region [V-clear] [V-copy]. They also act on an in/out range [HM p. 28-29].
- Since build 2644, a triple-click on a region sets the in and out points around it (known). Inference: a region selection and a range can be the same span.
- No source says which one wins when a region selection and a different in/out range exist at the same time (unconfirmed).

## 13. Apple facts

Pasteboard:

- The pasteboard server "is shared by all running apps". An `NSPasteboard` object is "an application's sole interface to the server" [A-PB].
- `NSPasteboard.general` is "the shared pasteboard object to use for general content" [A-GEN]. It "automatically participates with the Universal Clipboard feature" [A-PB].
- Write in this order: `clearContents()`, then `setData(_:forType:)` [A-PB]. `clearContents()` "Clears the existing contents of the pasteboard". It returns the change count [A-CLR].
- `changeCount` "increments each time the pasteboard ownership changes". Record it when you take ownership. Compare it later to know if you are still the owner [A-CHG].
- `declareTypes(_:owner:)` is equal to `clearContents()` plus one first item with promised types. Do not use it with `writeObjects(_:)` [A-DECL].
- A pasteboard item "is only valid until the owner of the pasteboard changes" [A-PBI].
- **Custom types.** `NSPasteboard.PasteboardType` has `init(_:)` and `init(rawValue:)` with a `String` [A-PBT]. The header says the first-item methods "accept UTIs and pboard type strings. In a future release they may take only UTIs" [A-PBH].
- **Declare the type.** Apple says to declare a custom type in `Info.plist` as an exported type when the app owns the format. Use a reverse-DNS identifier. Do not use the prefixes `public`, `dyn`, or `com.apple` [A-UTD]. `UTType(exportedAs:)` "asserts that you own the type definition" [A-UTX]. No NSPasteboard page says that a pasteboard type must have an `Info.plist` declaration (not documented).
- **Audio types.** The documented pasteboard types include `sound` ("Sound data"), `fileURL` ("A file URL"), and `fileContents` [A-PBT] [A-PBS] [A-PBF]. The header says `NSPasteboardTypeFileURL` is "Equivalent to kUTTypeFileURL" [A-PBH].
- `NSSound` conforms to `NSPasteboardReading` and `NSPasteboardWriting` [A-PBH]. A local probe on the macOS 26.2 SDK printed the raw value `com.apple.cocoa.pasteboard.sound` for `.sound` and `public.file-url` for `.fileURL`. `NSSound.readableTypes(for:)` returned only the sound type [A-PROBE].
- `UTType.aiff` has the identifier `public.aiff-audio`. It conforms to `public.aifc-audio`, and then to `public.audio` [A-AIFF].
- No Apple page documents AIFF data as a pasteboard type for audio (not documented).

Finder:

- `activateFileViewerSelecting(_:)` "Activates the Finder, and opens one or more windows selecting the specified files". It is safe from any thread [A-AFV].
- `selectFile(_:inFileViewerRootedAtPath:)` "Selects the file at the specified path". It does not follow symlinks. It is safe from any thread [A-SEL]. The header adds: if `fullPath` is nil, it opens the directory `rootFullPath`. If `rootFullPath` is empty, it uses the main viewer. Otherwise it opens a new viewer [A-WSH].
- The behavior for a URL inside a package is not documented for either method [A-AFV] [A-SEL] [A-WSH].

Menu keys:

- For Backspace as a key equivalent, use a one-character string with `NSBackspaceCharacter` (0x08). For Forward Delete, use `NSDeleteCharacter` (0x7F). "These are not the same characters you get from an NSEvent key-down event" [A-KEQ] [A-BS] [A-DEL].
- SwiftUI `KeyEquivalent.delete` is U+0008. `.deleteForward` is U+F728. `.return` is U+000D [A-KD] [A-KDF] [A-KR].
- **HIG Edit menu.** The items are, in order, Undo, Redo, Cut, Copy, Paste, Paste and Match Style, Delete, Select All, and more [HIG-MB].
- Cut "Removes the selected data and stores it on the Clipboard". Copy "Duplicates the selected data and stores it on the Clipboard". Paste "Inserts the contents of the Clipboard at the current insertion point" [HIG-MB].
- Delete "Removes the selected data, but doesn't place it on the Clipboard". "Provide a Delete menu item instead of an Erase or Clear menu item. Choosing Delete is the equivalent of pressing the Delete key" [HIG-MB].
- Undo: "Clarify the target of the undo", for example "Undo Paste and Match Style" [HIG-MB].
- Standard keys: Cmd-X, Cmd-C, Cmd-V, Cmd-A (select all), Shift-Cmd-A (deselect all), Cmd-Z, and Shift-Cmd-Z for Redo [HIG-KB]. The HIG also lists Command-Space for Spotlight [HIG-KB].
- Inference: Hindenburg names the command "Clear" [V-clear]. The HIG asks for "Delete".

## Sources

New Hindenburg sources (the other tags are in `docs/research/timeline-playback.md` and `docs/research/timeline-view.md`):

- [HM] Hindenburg Journalist 1.21 user guide for macOS: https://www.willyurman.com/teaching/handouts/Hindenburg_Journalist.pdf
- [HW] Hindenburg Journalist guide for Windows: http://hindenburgsystems.com/wordpress/wp-content/uploads/2010/07/Hindenburg-Journalist-Guide-Windows.pdf
- [KB-blank] Blank regions: https://hindenburg.uservoice.com/knowledgebase/articles/1882393-blank-regions
- [UV-cursor] Cursor behavior for marking and selecting (2015): https://hindenburg.uservoice.com/forums/224350-general/suggestions/7275054-cursor-behavior-for-marking-and-selecting
- [Rnnnn] build nnnn at `https://hindenburg.com/release-notes-hindenburg-pro_version-2/<page>/`: [R2544] pro-v2_build-2544, [R2550] pro-v2_build-2550, [R2572] pro-v2_02-build-2572, [R2752] pro-v2_05-build-2752

Official Hindenburg videos (https://www.youtube.com/watch?v=<id>), description and frames. The function pages are `https://hindenburg.com/data/functions/<name>/`:

- [V-selregion] ppUzYqvYLRc (regions-select-region)
- [V-movetrack] zbs6FP8TseQ (regions-move-regions-between-tracks)
- [V-trim] _NFYvUDvLXk (regions-trim)
- [V-shuffle] 99TZDlaO5_I (regions-shuffle-trim-slip-edit)
- [V-slide] GDGJzqNG0OI (regions-slide-audio-inside-region)
- [V-group] J0fM11rWGBQ (regions-group)
- [V-props] kQQHtWpuG-k (regions-properties-region)
- [V-deltrack] s2aSd_hWzk4 (tracks-delete-track)
- [V-clip] KjZmQnbicCg (clipboards-clipboard)
- [V-clipdrag] a1AENcgri-c (clipboards-drag-regions)
- [V-clipsel] 699fP7UTlFQ (clipboards-drag-selection)
- [V-clipmove] ezPwVSjp134 (clipboards-move-regions)
- [V-clippaste] reUEBwjAnJo (clipboards-paste-clip)
- [V-clipinsert] XbYtFvnr2-g (clipboards-insert-clip)
- [V-clipboard2] E9qFtiZ_gTY (clipboard-add-soundbites, clipboard-copy-as-text)
- Reused tags: [V-drag] P8YW91vfCH8, [V-cmdclick] WdeTWfpnKBY, [V-nudge] L0jW1X95rQA, [V-snap] O4pvSwPF5Qo, [V-clear] eaALdtdc1bw, [V-copy] TWkLl4FaAqc, [V-paste] l76NLrkHIZo, [V-split] LgX_53lS27E, [V-marquee] VRmxSBgB8XM, [V-marker] wd4SjWBdloM, [V-mrename] _WZeKsFj_1g, [V-mdelete] JFz6EDEBKso, [V-markers] f4f-DI995fg, [V-event] K55VYJ2YL4s, [V-chapter] KCh_qgwUBH0, [V-chapters] _inn9JToMGU, [V-finegrid] OHx9PAN4nJc

Apple (https://developer.apple.com/documentation/<path>):

- [A-PB] appkit/nspasteboard
- [A-GEN] appkit/nspasteboard/general
- [A-CLR] appkit/nspasteboard/clearcontents()
- [A-CHG] appkit/nspasteboard/changecount
- [A-DECL] appkit/nspasteboard/declaretypes(_:owner:)
- [A-PBI] appkit/nspasteboarditem
- [A-PBT] appkit/nspasteboard/pasteboardtype (and its init(_:) and init(rawvalue:) pages)
- [A-PBS] appkit/nspasteboard/pasteboardtype/sound
- [A-PBF] appkit/nspasteboard/pasteboardtype/fileurl
- [A-PBH] Local header `NSPasteboard.h` in `MacOSX26.2.sdk`, `System/Library/Frameworks/AppKit.framework/Headers/`
- [A-PROBE] Local Swift probe on 2026-09-25, macOS SDK 26.2: prints `PasteboardType.sound.rawValue`, `PasteboardType.fileURL.rawValue`, and `NSSound.readableTypes(for: .general)`
- [A-UTD] uniformtypeidentifiers/defining-file-and-data-types-for-your-app
- [A-UTX] uniformtypeidentifiers/uttype-swift.struct/init(exportedas:conformingto:)
- [A-AIFF] uniformtypeidentifiers/uttype-swift.struct/aiff
- [A-AFV] appkit/nsworkspace/activatefileviewerselecting(_:)
- [A-SEL] appkit/nsworkspace/selectfile(_:infileviewerrootedatpath:)
- [A-WSH] Local header `NSWorkspace.h` in `MacOSX26.2.sdk`, `System/Library/Frameworks/AppKit.framework/Headers/`
- [A-KEQ] appkit/nsmenuitem/keyequivalent
- [A-BS] appkit/nsbackspacecharacter
- [A-DEL] appkit/nsdeletecharacter
- [A-KD] swiftui/keyequivalent/delete
- [A-KDF] swiftui/keyequivalent/deleteforward
- [A-KR] swiftui/keyequivalent/return
- [HIG-MB] Human Interface Guidelines, The menu bar: https://developer.apple.com/design/human-interface-guidelines/the-menu-bar
- [HIG-KB] Human Interface Guidelines, Keyboards: https://developer.apple.com/design/human-interface-guidelines/keyboards
