# 0014. The session window: one AppKit window per package, autosave through Studio, no Versions yet

- Status: accepted
- Date: 2026-09-24
- Amended: 2026-09-24. The meter before a take and the device-list listener are in 0015. The 2 s poll of the device list goes.
- Amended: 2026-09-24. A Transport menu holds the plain-key commands (Space, Shift-Space, J, K, L, Home, End, Shift-Left, Shift-Right). A take starts at the Studio playhead, not after the last clip (see 0016).
- Amended: 2026-09-27. Each window has an AppKit toolbar and a subtitle; its hosting controller has `sceneBridgingOptions = []`; a chrome object beside the window owns them. `ToolbarCommands` adds Show/Hide Toolbar and Customize Toolbar…. A new window opens at 1180 x 720 pt and cascades; the minimum width is 720 pt. An empty session shows an Add Track button. Stop (Command-period) is in the Transport menu: it stops a take, else a play (see 0023).
- Amended: 2026-10-04, run 11b-2. While the inspector shows, the minimum width is 720 pt plus the inspector width (240 to 400 pt, amended 2026-10-11); see 0023.
- Amended: 2026-09-30. The launch and a Dock click with no session window show the start window, not the Open panel. The close of the last session window shows it too. New Session (Command-N) shows the start window, not a save panel; its Create still calls `Studio.create` (see 0027).
- Amended: 2026-10-03. At open, a window arms each routed track in track order, except a track that uses a channel or an app of an earlier armed track (`tracksToArm`, run 6b). Two armed tracks on one channel stop a take.
- Amended: 2026-09-30. Open Recent and the start window read the recent sessions from the app preferences (key `recent.sessions`, absolute paths, 10 at most), not from `recentDocumentURLs`. The list of `NSDocumentController` belongs to the code signature, and each ad-hoc build has a new one. The app still calls `noteNewRecentDocumentURL` for the Dock menu (see 0027).
- Amended: 2026-10-08, run app-bug-batch. In the Stop and Close question, Stop and Close is the default button (Return) with no destructive style, as Stop and Quit; Cancel has the cancel role (Esc). The questions after a failed save, Close and Quit, have the destructive style and no Return; Esc gives Cancel. One key must not drop edits that Undo cannot give back.
- Amended: 2026-10-09, run `2026-10-09-autosave-backups` (see 0043). Versions is decided: it takes no part. Backups are copies of `session.xml` in `Backups/` of the package, and File > Revert To restores one as one undo entry that keeps `<recording>`.

## Context

Release 1 run 3 (`docs/requirements/releases.md`) adds the first window. It opens a `.dirigible` package, edits tracks and routes, records and stops, and shows the take state. `Studio` (0004, 0012, 0013) already owns the package lock, the recovery at open, and the start and stop order. The user asked for a decision on macOS Versions and an undo history on disk before or with this run.

Probes on 2026-09-24 (macOS 15.7.9, x86_64, APFS, Swift 6.2.4; `.scratchpads/runs/2026-09-24-record-ui/probe/output.txt`) and `docs/research/document-window.md`:

- P1. An `NSDocument` save of a package (the save path under `DocumentGroup`) writes a new folder and swaps it in. With a new wrapper, it deletes `.lock`, `Capture/`, and the open CAF, and a second `flock` succeeds. With the wrapper read from disk, it hard-links each file, but a file that a writer makes after the read is lost (research section 1).
- The private document class of `DocumentGroup` keeps `autosavesInPlace` and `preservesVersions` true, and its read configuration has no URL (research section 5).
- P2. A Versions entry of a package with a 1 GiB file takes 0.026 s and 0 to 4 MiB (an APFS clone). A restore replaces the whole package and deletes a newer take.
- P5. `WindowGroup(for: URL.self)` makes a new window with a nil value for each opened file and gives the delegate an empty list. A SwiftUI app with only a `Settings` scene gives each URL to `application(_:open:)`, and a dictionary keyed by the resolved URL stops a duplicate window. `noteNewRecentDocumentURL` works with no `NSDocument` subclass.
- P7. In this app shape, `applicationOpenUntitledFile` is not called. Open events come before `applicationDidFinishLaunching`.
- P3. `.userInitiated` contains `.idleSystemSleepDisabled`. `[.userInitiatedAllowingIdleSystemSleep, .latencyCritical]` makes no IOPM assertion.
- P4. macOS binds Control-Space (hot key 60) to "Select the previous input source" by default.
- P11 (2026-09-25). After a rename, a move on one volume, or a move to the Trash, `fcntl(F_GETPATH)` on the held `.lock` descriptor gives the new path, and the lock and the open CAF files follow the package. After a move to another volume or a delete, `F_GETPATH` gives the old path with no error, and a second `flock` on the copy succeeds.
- P12 (2026-09-25). A SwiftUI `CommandGroup` Undo button with Command-Z runs while a text field has focus, and the typing is not undone. The default Edit items send `undo:` and `redo:` through the responder chain; the field editor does not handle `undo:`, and `NSWindow` undoes the typing with the window `UndoManager`.
- P13 (2026-09-25). `F_FULLFSYNC` works on a folder descriptor. `Session.write(to:)` flushes the parent folder only when it made the package folder.
- P14 (2026-09-25). `fstatfs` on the held `.lock` descriptor gives the free space of the package volume after a rename. `statfs` of the old path fails with `ENOENT`. After a move to another volume or a delete, `fstatfs` gives the old volume with no error.
- P15 (2026-09-25). A parent folder with an inherit-only deny ACL lets `mkdir` make a package folder and refuses the first file in it. A full HFS+ volume refuses the `mkdir` itself.

## Decision

**Window shell.** The SwiftUI `App` has only a `Settings` scene, with the Settings menu item removed, and `.commands`. The app delegate owns a registry of one `NSWindow` with an `NSHostingController` per package, keyed by `url.standardizedFileURL.resolvingSymlinksInPath()`. A close removes the entry of its window, also when a move changed its key. A second open of a package brings its window to the front. Open Recent uses `NSDocumentController.shared.noteNewRecentDocumentURL` and `recentDocumentURLs`. The app has no `NSDocument` subclass and no `DocumentGroup`.

**Studio is the model.** `Studio` becomes `@Observable`. The views read it directly. The app adds only window state: the armed tracks, the device list, and the alert. The armed tracks are not saved; a window arms every track that has a route.

**Saves.** Every package write of a `Studio` runs in one chain, in order: the autosave after an edit, undo, or redo; the start save of `<recording>`; and the finalize save. So an old autosave never lands after the `<recording>` save. The writes run off the main actor. There is no Save command and no "edited" state. `Studio.save()` goes; `Studio.settle()` stops a take, waits for every write, and writes once more when the last autosave failed. An autosave error shows in the window, and the next edit tries again.

**A moved package.** Every write of a lock holder (the `Studio` saves and the CLI edit) goes to `PackageLock.package()`: the `F_GETPATH` path of the lock descriptor, when `stat` of `<path>/.lock` has the `st_dev` and `st_ino` of the descriptor (P11). Otherwise the write refuses with `.packageMoved`, and it never makes a folder. Each result of `package()` goes through `packageIdentity`, because `F_GETPATH` gives the `/private` spelling. A take resolves the path once at the start and again when a device writer opens a segment. The disk check reads `fstatfs` on the lock descriptor (P14), so a rename never stops a take as disk low. The finalize makes `Clips/` with `mkdir` of that folder only, and a listed CAF that is gone is a take-wide error. `Studio.url` follows the move at the next write, and the window title, the window registry, and the active-recordings entry follow `Studio.url`. Until that write, they keep the old path: a second open of the moved package gives a window that fails with `.locked`, and an open at the old path finds the old window. So a reader of the package (the pending space, the record time) resolves `lock.package()` off the main actor, never `Studio.url`. A registry key never replaces the entry of another window: when the new key is taken, the window keeps its old key, so a Quit still settles both windows. A finalize that finds no `Capture/` while `<recording>` exists throws, and the take stays pending.

**New session.** `Session.create(at:sampleRate:)` makes the package folder with `mkdir`, so it never replaces a path that exists (`.exists`). It writes `session.xml`, then flushes the parent folder. A failure after `mkdir` removes the new folder. The rate is 48,000 Hz. The CLI `create` uses the same call. The app New Session calls `Studio.create`, which makes the package with `Session.create` and opens it; the window takes that open studio.

**No Versions and no undo journal in Release 1.** A Versions restore deletes newer takes (P2), and the `NSDocument` path that offers Versions swaps the package (P1). The Release 2 autosave design (F62) decides again, with these rules: a revert restores `session.xml` only, as one undo entry that keeps `<recording>` (0003, 0004); no `NSDocument` save path writes the package. (Amended by 0043: Versions takes no part; backups are copies of `session.xml` in the package.)

**Active recordings.** `ActiveRecordings` in `DirigibleAudio` is the 0004 hint: a plist array of package paths. `Studio` adds the package after the start save and before the attach, and removes it after the save that removes `<recording>`. `Studio.open` sets it from `session.recording` after its save. The app gives the file `~/Library/Application Support/com.delineas.dirigible/active-recordings.plist`; a write makes the folder when it is missing, and a failed write is logged. The CLI and the tests give none. At launch, the app reads the list once, off the main actor, opens each listed package that exists, and shows the Open panel when no window opened.

**Meters.** The drain computes the peak of each track from the samples that it copies anyway, and sends it with the dropped-frame count through the report closure, once per drain per device. `Studio.liveTracks` is stored and observable. The IOProc does not change. A meter shows during a take only; a meter before a take is the input-monitor run.

**Keys.** Record is Command-R, Stop is Command-period, Retry Finalize is Option-Command-R, Add Track is Option-Command-N, New Session is Command-N. Control-Space belongs to macOS (P4). A plain letter would fire while a track name field has focus. Undo and Redo are the default Edit items (`undo:`, `redo:`), not a `CommandGroup` (P12). The window content controller routes them: a focused text field gets the text undo; otherwise `Studio` undoes a session edit.

**Close and Quit.** During a take, the window asks "Stop and Close" (or "Stop and Quit") and then stops, finalizes, and saves before it closes. A pending take does not block a close. When the last autosave failed and the write in `settle()` also fails, the window asks before it closes (or quits). Cancel keeps the window open with its `Studio`.

**App Nap.** During a take, `Studio` also holds `ProcessInfo.beginActivity([.userInitiatedAllowingIdleSystemSleep, .latencyCritical])`. The IOPM assertion of 0013 stays the only sleep assertion.

## Consequences

- 0002 gets an amended line: `DirigibleApp` depends on `DirigibleAudio`, and `DirigibleTests` depends on `DirigibleApp` for the string test.
- 0004 gets an amended line: the active-recordings list is a plist that `Studio` keeps; the app owns its path.
- 0010 is amended: dotted keys and the `L10n` enum.
- Each edit saves with `F_FULLFSYNC`. The test suite pays this for each `studio.edit`.
- The app has no window restoration for sessions with no take. Open Recent lists them.
- A package path with other letter case gives a second window that fails with `.locked`.
- A take appends after the last clip of the session until the timeline run adds a playhead.
- A move to another volume during a take loses the audio after the move: the IOProcs write into deleted files (P11). The copy keeps `<recording>` and the audio up to the move, and its open recovers it.
- A package on a volume without `flock` has no lock descriptor, so a move there is not followed (the 0012 SMB limit).

## Alternatives considered

- **`DocumentGroup` with `ReferenceFileDocument`.** Finder open, Open Recent, restoration, and Versions for free. Rejected: its save deletes `Capture/` and frees the lock (P1), and the app cannot turn off its autosave in place.
- **An `NSDocument` subclass that refuses every write path.** It needs about 14 overrides, two of them `fatalError`. A missed path in a later SDK deletes audio, and no test sees it. Rejected.
- **`WindowGroup(for: URL.self)` with `onOpenURL`.** Rejected: a duplicate window for each open (P5a to P5c).
- **A session controller in the library that the views bind to.** Rejected: it copies `Studio.transport`, so two states must stay in sync.
- **Meter atomics that a `TimelineView` polls.** Rejected: the atomic keeps the last record, not the maximum since the last read, and the dropped frames still need a poll.
- **Versions now, with a revert of `session.xml` only.** Deferred to F62: autosave and backups are one Release 2 design.
