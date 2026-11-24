# Document window: saving, versions, file opening, and record keys

Date: 2026-09-24

## Scope

This document answers nine questions for the document window of Dirigible. A session is a file package (`LSTypeIsPackage` in `Support/Info.plist`). The recorder writes CAF files into the package while the window is open. The questions: how AppKit and SwiftUI save and revert a package, how a non-document SwiftUI app opens a file, how to keep the Mac awake during a recording, and which Record key to use.

Header citations use the Xcode 26 SDK (`MacOSX.sdk`, SDK 26.2) as `<header>:<line>`. The headers are under `$(xcrun --show-sdk-path)/System/Library/Frameworks/`. A claim with "[P]" comes from a local probe on this Mac (macOS 15.7.9, APFS boot volume, 2026-09-24). The section "Local probes" describes each probe so that you can run it again. A claim that no primary source confirms has the mark "(unconfirmed)".

## 1. NSDocument safe save replaces the package folder

- `writeSafely(to:ofType:for:)` either writes into a temporary directory or renames the old file aside. Then it calls `write(to:ofType:for:originalContentsURL:)`, and it moves the new file into place. "The details of this are subject to change" [1] `NSDocument.h:290-294`. The archived guide says the same [9].
- Autosave in place "performs a safe save by writing to a new file first, then moving it into the place of the document file" [8].
- The operations: `NSSaveOperation` overwrites the document file on a user command. `NSAutosaveInPlaceOperation` overwrites it without a user command. `NSSaveAsOperation` writes a new file and makes it current. `NSAutosaveElsewhereOperation` writes a separate file and does not change the current one. With `autosavesInPlace`, NSDocument uses autosave elsewhere only for a document that has no file yet [1] `NSDocument.h:57-81`.
- [P] `writeSafely` with `.saveOperation` and with `.autosaveInPlaceOperation` gave the package folder a new inode. It also gave `Clips/` and the rewritten `session.xml` new inodes. An unchanged child (`Clips/a.caf`) kept its inode. No backup item stayed next to the package.
- `FileWrapper.write(to:options:originalContentsURL:)` writes hard links to unchanged regular files when `originalContentsURL` is not nil [4] `NSFileWrapper.h:100`. The hard links need correct child file names. `NSFileWrapperWritingWithNameUpdating` helps with that [4] `NSFileWrapper.h:30`. The archived guide recommends that you keep the child wrappers for incremental saves [9]. Clones are not mentioned. The system call that swaps the folder (`renamex_np`, `exchangedata`, or `FileManager.replaceItemAt`) is not documented (unconfirmed). `FileManager.replaceItemAt` is the documented safe save for code outside NSDocument [5] `NSFileManager.h:287-294`.
- **Data-loss risk.** A child wrapper of a package reads its children lazily, unless you use `NSFileWrapperReadingImmediate` [4] `NSFileWrapper.h:14`. The save writes only the children that the wrapper knows. [P] A file that another writer added to `Clips/` after the wrapper enumerated `Clips/` was deleted by the save. A file added before the enumeration survived with its inode.
- Methods that you can override:
  - `writeSafely(to:ofType:for:)`. You can write in place without super, but the header advises against it [1] `NSDocument.h:300`. If `backupFileURL` is not nil, your override must move the old contents there, or you must override `backupFileURL` to return nil [1] `NSDocument.h:324-331`. An app that saves in place "will almost always want to disable this optimization" [10] (10.8 notes).
  - `write(to:ofType:for:originalContentsURL:)` gets the old file location [1] `NSDocument.h:304-308`.
  - `save(to:ofType:for:completionHandler:)` wraps every save. Invoke super [1] `NSDocument.h:396`.
  - `keepBackupFile` has no effect when `preservesVersions` is true [1] `NSDocument.h:320-322`. Do not return true when `autosavesInPlace` is true [10] (10.7 notes).
  - `canAsynchronouslyWrite(to:ofType:for:)` is false by default. If it is true, the write runs off the main thread [1] `NSDocument.h:402-404`.
  - `autosavesInPlace` is false by default. `preservesVersions` returns `autosavesInPlace` by default [1] `NSDocument.h:442-452`.

## 2. NSDocument reacts to other writers in the package

- NSDocument is an `NSFilePresenter` [1] `NSDocument.h:90`. It implements `presentedItemDidChange`, `relinquishPresentedItemToWriter:`, and the other presenter methods [1] `NSDocument.h:816-831`. Apple's presenter docs say that `presentedItemDidChange` reports changes to "the files in a directory" and to attributes [11].
- [P] With `autosavesInPlace` true, a coordinated write of a new file in `Clips/` caused `presentedItemDidChange`. A clean document then called `revert(toContentsOf:ofType:)` and read the package again. With `autosavesInPlace` false, there was no revert. An uncoordinated write caused `presentedItemDidChange` but no revert in 4 s.
- [P] An override of `presentedItemDidChange` that does not call super stopped the revert.
- At save time, `saveDocument` checks whether "something other than the current application" modified, moved, renamed, or deleted the file since it was opened or saved [1] `NSDocument.h:352-356`. The alert text is "This document's file has been changed by another application since you opened or saved it" [10] (10.5 notes). The check uses `fileModificationDate` [1] `NSDocument.h:147-149`.
- To turn the checks off, override `presentedItemDidChange`, or set `fileModificationDate` after your own writes (unconfirmed). You can also override `saveDocumentWithDelegate:didSaveSelector:contextInfo:`. Whether the check reads the modification date of the package root or of each child is not documented (unconfirmed).

## 3. Move, rename, duplicate, lock, and browse versions

| Action | What it does on disk | Override |
|---|---|---|
| Move To | A coordinated move of the file to the new URL. It replaces a file that is already at the URL [1] `NSDocument.h:540-544`. [P] A move on one volume keeps the files: after `rename(2)`, `FileManager.moveItem`, or `trashItem`, a held `flock` and an open CAF descriptor follow the package. A move to another volume is a copy and a delete. | `moveDocument(_:)`, `moveToURL(_:completionHandler:)` |
| Rename (title bar) | Starts a rename session in the window [1] `NSDocument.h:520-522`. The disk operation is a move (unconfirmed). | `renameDocument(_:)` |
| Duplicate | Writes the full document with `writeSafely` into the autosave folder of untitled documents. Then it opens that copy as a new document [1] `NSDocument.h:510-516`. For a package, the copy includes all audio (unconfirmed for hard links). | `duplicateDocument(_:)`, `duplicate()` |
| Lock | Autosaves, then sets the "user immutable" flag on the file at `fileURL` [1] `NSDocument.h:553-563`. On a package, only the folder gets the flag (unconfirmed). | `lockDocument(_:)`, `lock(completionHandler:)` |
| Browse All Versions, Revert To | Opens the Versions browser. A restore keeps the current contents as a version, then replaces the file contents with the selected version [8]. | `browseDocumentVersions(_:)`, `revert(toContentsOf:ofType:)` |

- `preservesVersions` false turns off the Versions browser and `revertDocumentToSaved:` [1] `NSDocument.h:448-450`. If `autosavesInPlace` is true and `preservesVersions` is false, `revertDocumentToSaved:` throws an exception [1] `NSDocument.h:222`.
- `validateUserInterfaceItem(_:)` enables the menu items of all these actions. Override it to disable an item [1] `NSDocument.h:807-809`.
- Before a duplicate or revert, NSDocument can write the current contents with `NSAutosaveElsewhereOperation` [10] (10.7 notes).
- [P] `fcntl(F_GETPATH)` on a held descriptor gives the current path after a rename, a move on one volume, or a move to the Trash. After a move to another volume or a delete, it gives the old path with no error. So a check must compare `st_dev` and `st_ino` of `stat(path)` with `fstat(descriptor)`.

## 4. macOS Versions (NSFileVersion)

- On the Mac, the document architecture makes versions at set points, and an app can add versions too [12].
- `addOfItem(at:withContentsOf:options:)` adds a version. Only macOS can add versions. Do it inside a coordinated write [3] `NSFileVersion.h:58-64`. `.byMoving` moves the contents into the store instead of a copy [3] `NSFileVersion.h:13-17`.
- `otherVersionsOfItem(at:)` never includes the current version [3] `NSFileVersion.h:38-40`. `removeOtherVersionsOfItem(at:)` deletes all other versions [3] `NSFileVersion.h:140-144`.
- `replaceItem(at:options:)` replaces the file with the contents of the version and keeps the display name [3] `NSFileVersion.h:126-130`.
- The store URL "will have an arcane path" [3] `NSFileVersion.h:70`. [P] On this Mac, the path was `/System/Volumes/Data/.DocumentRevisions-V100/PerUID/501/<hex>/com.apple.documentVersions/<UUID>.dirigible`.
- [P] A package is stored as a whole. The version URL was a `.dirigible` folder with the same children.
- [P] The version is an APFS clone. The first block of `a.caf` in the version and in the original had the same physical offset (`F_LOG2PHYS`). A rewritten copy had a different offset. A free-space measurement was noisy (176 MB and 199 MB for a 400 MB file), so it proves nothing.
- [P] `replaceItem(at:)` replaced the whole package. The package got a new inode. `Clips/b.caf`, which was added after the version, was deleted.
- Volume support is not documented (unconfirmed). [P] `addOfItem` worked on the boot Data volume. It failed with `NSCocoaErrorDomain` 512 on disk images with APFS, HFS+, FAT32, and ExFAT. Real external drives were not tested.
- With `backupFileURL`, NSDocument makes a version by a move of the old file instead of a copy [1] `NSDocument.h:326`, [10] (10.8 notes).

## 5. SwiftUI DocumentGroup on macOS 14

- [P] SwiftUI has a private class `SwiftUI.PlatformDocument`. Its superclass chain is `NSDocument -> NSObject`. Its `autosavesInPlace` and `preservesVersions` return true. The app cannot change these values. That DocumentGroup uses this class is an inference from its name and symbols in `SwiftUI.tbd` (unconfirmed).
- So DocumentGroup gets the behavior of sections 1 to 4: safe save that replaces the package, automatic revert of a clean document, and Versions.
- `ReferenceFileDocument` has `init(configuration:)`, `snapshot(contentType:)`, and `fileWrapper(snapshot:configuration:)` [7] `swiftinterface:7979-7987`. SwiftUI calls these methods "from different isolation domains" [14].
- `FileDocumentReadConfiguration` has only `contentType` and `file: FileWrapper`. It has no URL [7] `swiftinterface:6068-6070`. `FileDocumentWriteConfiguration` has `contentType` and `existingFile: FileWrapper?` [7] `swiftinterface:6058-6060`.
- NSDocument's default `read(from:ofType:)` "creates an NSFileWrapper" [1] `NSDocument.h:236`. Children load lazily, unless the reader uses `NSFileWrapperReadingImmediate` [4] `NSFileWrapper.h:14`. The options that SwiftUI uses are not documented (unconfirmed).
- The URL is available only in the view. `ReferenceFileDocumentConfiguration.fileURL` exists since macOS 11 [7] `swiftinterface:8004-8022`. `EnvironmentValues.documentConfiguration` and `DocumentConfiguration.fileURL` exist since macOS 14 [7] `swiftinterface:16043-16064`, [15].
- Save trigger: a `FileDocument` changes through its binding. A `ReferenceFileDocument` must register an undo action with the environment `UndoManager` for every change [13], [14].
- New: `DocumentGroup(newDocument:editor:)` calls the closure for an untitled document [7] `swiftinterface:8001`. NSDocument autosaves an untitled document into `~/Library/Autosave Information` [10] (10.7 notes). So a new session has no permanent folder until the user saves it (unconfirmed for SwiftUI).
- Menu: `.saveItem` holds Close, Save, Save As/Duplicate, and Revert to Saved on macOS. `.newItem` holds New. `.importExport` is empty [16]. `CommandGroup(replacing:)` can replace these groups. Whether Rename and Move To are in `.saveItem` is not documented (unconfirmed).

## 6. A non-document SwiftUI app that opens a file

- `application(_:open:)` gets the URLs that the app is asked to open. This includes documents that have no NSDocument class. If the delegate implements it, AppKit does not call `application(_:openFile:)` or `application(_:openFiles:)` [19]. Add the delegate with `NSApplicationDelegateAdaptor` [7] `swiftinterface:15943`.
- `handlesExternalEvents(matching:)` routes a URL by its `absoluteString`. An open scene that prefers the event gets it first. Otherwise SwiftUI makes a new instance of the first matching scene, or of the first scene without the modifier. DocumentGroup ignores this modifier [17].
- `onOpenURL(perform:)` receives the URL in the scene that SwiftUI selects [18].
- Whether SwiftUI still opens a new window when the delegate implements `application(_:open:)` is not documented (unconfirmed). Test it with `open file.dirigible`, a double-click, and a drop on the Dock icon.
- Open Recent: `noteNewRecentDocumentURL(_:)` works "even in non-NSDocument-based applications". `recentDocumentURLs` returns the menu entries [2] `NSDocumentController.h:233-241`. The menu item for a WindowGroup app and the path that opens a selected entry are not documented (unconfirmed).
- Restoration: `WindowGroup(for:)` is on macOS 13 and later [7] `swiftinterface:16246-16268`. SwiftUI persists the presented value and reapplies it when it restores the window. On an error, it uses the default value or nil [20]. `URL` is `Codable` and `Hashable`, so it can be the value. `restorationBehavior(_:)` needs macOS 15 [7] `swiftinterface:274-276`. The app is not sandboxed, so a path URL needs no bookmark. After a move of the file, a saved path URL points to nothing (P11 in the record-ui run: only a held descriptor follows the move).

## 7. Keep the Mac awake during a recording

- `.userInitiated` is `0x00FFFFFF | idleSystemSleepDisabled`. It includes `.idleSystemSleepDisabled`, `.suddenTerminationDisabled`, and `.automaticTerminationDisabled` [6] `NSProcessInfo.h:133-155`. So `[.userInitiated, .idleSystemSleepDisabled]` is the same as `.userInitiated`.
- `.idleSystemSleepDisabled` stops idle system sleep [6] `NSProcessInfo.h:135-136`, [23]. It does not stop display sleep. That is `.idleDisplaySleepDisabled` [6] `NSProcessInfo.h:132-133`.
- `.latencyCritical` asks for "the highest amount of timer and I/O precision". The header reserves it for "activities like audio or video recording" [6] `NSProcessInfo.h:99, 161-162`. `.userInteractive` is `.userInitiated | .latencyCritical` on macOS 13 and later [6] `NSProcessInfo.h:163-164`.
- App Nap lowers priority, throttles timers, and throttles I/O. An app is a candidate if it is not in the foreground, is not audible, and has no power or `NSProcessInfo` assertion [21]. A user-initiated activity keeps the app out of App Nap [22]. A recording is not audible, so it needs the activity.
- [P] `beginActivity(options: [.userInitiated, .idleSystemSleepDisabled, .latencyCritical], reason:)` made a `PreventUserIdleSystemSleep` assertion with the reason as its name (`pmset -g assertions`). The control, `[.userInitiatedAllowingIdleSystemSleep, .latencyCritical]`, made no assertion. So the flag is the same as that IOPM assertion type.
- End the activity. The header warns that a forgotten sleep activity hurts the user [6] `NSProcessInfo.h:119`.

## 8. Hindenburg PRO record UI

- Arm: the Arm Rec button in the track header arms the track. "The small meter will show input levels" [24] p. 19. The PRO 2 key for Arm Track is Shift-R [25]. The 1.21 manual lists R [24]. Shift-click on the Arm button disarms a track [27] (text from a search index, unconfirmed on the page).
- Track header: track name, volume, pan, record, monitor, mute, solo, and effects [24] p. 9. A per-track input selector is shown in a Hindenburg video "How to select input hardware" (unconfirmed, video not watched).
- Input monitoring: "With Record Monitor On you can listen to the incoming signal on a track before begin recording." Right-click the Arm Rec button to turn it on or off [26]. The manual warns about latency on a microphone signal [24] p. 19.
- Keys: Record is Control-Space [24] p. 19, [25]. Space toggles Play and Stop [25]. The PRO 2 page writes "Ctrl" also for New and Save [25]. The Mac manual uses ⌘ for those, so "Ctrl" on that page can mean Command (unconfirmed). Menu names of Record and Stop are not documented (unconfirmed).
- Device lost during a recording: no Hindenburg source found (unconfirmed).
- Saving: the 1.21 manual says "Hindenburg Journalist has a Auto Save function. If the program should fail the last session will be recovered" [24] p. 86. A user request for autosave from 2014 is still "under review" with comments from 2020 [28]. No source says that Hindenburg uses macOS Versions (unconfirmed). It uses its own session files.

## 9. Record key conflicts

- Control-Space selects the previous input source. Control-Option-Space selects the next one [29], [30]. On this Mac, symbolic hotkey 60 is `(32, 49, 262144)`: Space, key code 49, Control. Here it has `enabled = 0` because the user turned it off. The default state is not recorded here (unconfirmed). If the hotkey is on, the app does not get the key (unconfirmed).
- Command-Space shows Spotlight [29].
- Command-R shows the original of an alias in the Finder, reloads in Safari and Calendar, and checks again in Software Update [29]. It is not a standard AppKit menu key (unconfirmed). TextEdit uses it for Show Ruler (unconfirmed).
- Shift-Command-R opens AirDrop in the Finder [29]. This is a Finder key, so it does not block an app key (unconfirmed).
- Option-Space and Shift-R are not on Apple's list [29]. In a text field, Shift-R types "R" and Option-Space types a non-breaking space (unconfirmed). A single-key Record must not fire when a text field has focus.
- Logic Pro and GarageBand: "Click the Record button in the control bar (or press R) to start recording." Space stops [31], [32]. In GarageBand, a record-enabled track also monitors its input [31].

## Local probes

The probes are small Swift programs, built with `swiftc -O` on 2026-09-24. They ran on macOS 15.7.9 on the APFS Data volume, and they are not in the repo.

- Save: an `NSDocument` subclass reads a package with `Clips/a.caf` and `session.xml`. It returns the read wrapper from `fileWrapper(ofType:)` with a new `session.xml`. The probe prints `lstat` inodes before and after `writeSafely`. A variant reads `Clips` children before another writer adds `Clips/foreign.caf`.
- Presenter: the document is added to `NSDocumentController.shared` and `NSFileCoordinator.addFilePresenter`. A coordinated write and a plain write add `Clips/new.caf`. The run loop runs 4 s, and the overrides log their calls.
- Versions: `addOfItem`, then a changed `session.xml` and a new `Clips/b.caf`, then `replaceItem(at:)` in a coordinated write. The clone check compares `F_LOG2PHYS` offsets. The volume check runs on `hdiutil` images.
- SwiftUI: `NSClassFromString("_TtC7SwiftUI16PlatformDocument")` and `class_getSuperclass`.
- Activity: `beginActivity`, then `pmset -g assertions` filtered by the process ID.
- Hotkeys: `defaults read com.apple.symbolichotkeys AppleSymbolicHotKeys`.
- Move (2026-09-25): a package with a held `flock` on `.lock` and an open CAF. The probe prints `F_GETPATH` of both descriptors after `rename(2)`, `FileManager.moveItem` on one volume, `moveItem` to an `hdiutil` APFS image, `trashItem`, and `removeItem`. It then tries a second `flock` at the new path.
- Undo key (2026-09-25): a SwiftUI app with only a `Settings` scene and an `NSWindow` that hosts a SwiftUI `TextField`. One build replaces `.undoRedo` with a `CommandGroup` button. The probe sends a synthetic Command-Z with `NSApp.sendEvent`, and `undo:` with `tryToPerform` from the first responder.

## Findings that affect the design

State on 2026-11-24: the shipped window is an AppKit `NSWindow` for each package with no `NSDocument` (decisions 0004 and 0014), not a `WindowGroup`. The sleep activity is `[.userInitiatedAllowingIdleSystemSleep, .latencyCritical]` (`Sources/DirigibleAudio/Studio/SleepAssertion.swift`). The findings below are the research of 2026-09-25.

- Do not let NSDocument or DocumentGroup save the package while the recorder writes into it. The safe save replaces the folder. It deletes a file that the wrapper did not enumerate.
- DocumentGroup has no switch for this. Its private NSDocument subclass autosaves in place and keeps versions. Prefer a WindowGroup window with our own atomic `session.xml` save.
- If NSDocument is used, override `writeSafely` to write only `session.xml` in place. Return nil from `backupFileURL`, and set `preservesVersions` to false.
- Versions restore replaces the whole package and deletes newer clips. Do not offer Versions for a session.
- Other writers trigger an automatic revert of a clean NSDocument. The recorder writes are "other writers" if they use file coordination.
- Open files through `application(_:open:)` and `WindowGroup(for: URL.self)`. Call `noteNewRecentDocumentURL(_:)` for Open Recent. Check the Finder, Dock, and `open` paths by hand.
- `restorationBehavior(_:)` needs macOS 15. On macOS 14, SwiftUI restores the URL value by default.
- During a recording, hold `beginActivity(options: [.userInitiated, .latencyCritical])`. `.userInitiated` already includes `.idleSystemSleepDisabled`.
- A SwiftUI `CommandGroup` Undo button with Command-Z runs while a text field has focus, and the typing is not undone [P]. Keep the default Edit items, which send `undo:` through the responder chain. The field editor does not handle `undo:`; `NSWindow` does, with the window `UndoManager`, where the typing is registered [P].
- Control-Space (Hindenburg) can collide with the input source key. R (Logic Pro, GarageBand) is a safer Record key when no text field has focus.
- Hindenburg shows the input meter on an armed track before a recording. Monitoring to the output is a separate per-track switch.

## Sources

1. `AppKit.framework/Headers/NSDocument.h`, MacOSX.sdk 26.2 (Xcode 26).
2. `AppKit.framework/Headers/NSDocumentController.h`, MacOSX.sdk 26.2.
3. `Foundation.framework/Headers/NSFileVersion.h`, MacOSX.sdk 26.2.
4. `Foundation.framework/Headers/NSFileWrapper.h`, MacOSX.sdk 26.2.
5. `Foundation.framework/Headers/NSFileManager.h:287-294` (`replaceItemAtURL:withItemAtURL:...` is "a safe-save without using the full NSDocument machinery"), MacOSX.sdk 26.2.
6. `Foundation.framework/Headers/NSProcessInfo.h`, MacOSX.sdk 26.2.
7. `SwiftUI.framework/Modules/SwiftUI.swiftmodule/arm64e-apple-macos.swiftinterface`, MacOSX.sdk 26.2.
8. Document-Based App Programming Guide for Mac, Core App Behaviors: https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/DocBasedAppProgrammingGuideForOSX/StandardBehaviors/StandardBehaviors.html
9. Document-Based App Programming Guide for Mac, Alternative Design Considerations: https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/DocBasedAppProgrammingGuideForOSX/AdvancedTopics/AdvancedTopics.html
10. AppKit Release Notes (older notes; sections for Mac OS X 10.5, 10.7, and 10.8): https://developer.apple.com/library/archive/releasenotes/AppKit/RN-AppKitOlderNotes/index.html
11. NSFilePresenter, `presentedItemDidChange()`: https://developer.apple.com/documentation/foundation/nsfilepresenter/presenteditemdidchange()
12. NSFileVersion: https://developer.apple.com/documentation/foundation/nsfileversion
13. DocumentGroup: https://developer.apple.com/documentation/swiftui/documentgroup
14. ReferenceFileDocument: https://developer.apple.com/documentation/swiftui/referencefiledocument
15. EnvironmentValues.documentConfiguration: https://developer.apple.com/documentation/swiftui/environmentvalues/documentconfiguration
16. CommandGroupPlacement `saveItem`, `newItem`, `importExport`: https://developer.apple.com/documentation/swiftui/commandgroupplacement/saveitem, https://developer.apple.com/documentation/swiftui/commandgroupplacement/newitem, https://developer.apple.com/documentation/swiftui/commandgroupplacement/importexport
17. Scene.handlesExternalEvents(matching:): https://developer.apple.com/documentation/swiftui/scene/handlesexternalevents(matching:)
18. View.onOpenURL(perform:): https://developer.apple.com/documentation/swiftui/view/onopenurl(perform:)
19. NSApplicationDelegate `application(_:open:)`: https://developer.apple.com/documentation/appkit/nsapplicationdelegate/application(_:open:)
20. WindowGroup: https://developer.apple.com/documentation/swiftui/windowgroup
21. Energy Efficiency Guide for Mac Apps, App Nap: https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/AppNap.html
22. Energy Efficiency Guide for Mac Apps, Prioritize Work at the App Level: https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/PrioritizeWorkAtTheAppLevel.html
23. ProcessInfo.ActivityOptions: https://developer.apple.com/documentation/foundation/processinfo/activityoptions
24. Hindenburg Journalist 1.21 user guide (Hindenburg Systems), hosted by willyurman.com: https://www.willyurman.com/teaching/handouts/Hindenburg_Journalist.pdf
25. Hindenburg PRO 2 shortcuts: https://hindenburg.com/academy/shortcuts/shortcuts-hindenburg-2-pro/
26. Hindenburg support, Record monitor on / off: https://hindenburg.uservoice.com/knowledgebase/articles/1911799-record-monitor-on-off
27. Hindenburg PRO guides: https://hindenburg.com/academy/guides/guides-hindenburg-pro/
28. Hindenburg support forum, Autosave suggestion: https://hindenburg.uservoice.com/forums/224350-general/suggestions/5736450-autosave
29. Apple Support, Mac keyboard shortcuts: https://support.apple.com/en-us/102650
30. Apple Support, Write in another language on Mac: https://support.apple.com/guide/mac-help/mchlp1406/mac
31. GarageBand for Mac, Record to multiple audio tracks: https://support.apple.com/guide/garageband/record-to-multiple-audio-tracks-gbnd5f260581/mac
32. Logic Pro for Mac, Record to multiple audio tracks: https://support.apple.com/guide/logicpro/record-to-multiple-audio-tracks-lgcpb19dcf78/mac
