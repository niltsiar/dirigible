# 0027. A start window that AppDelegate owns, in place of the launch Open panel and the New Session save panel

- Status: accepted
- Date: 2026-09-30
- Accepted: 2026-09-30, after plan gate 1 of run `2026-09-30-start-window` and the architect synthesis of that run.
- Amends: 0014 (the launch shows the start window, not the Open panel; New Session shows the start window, not a save panel; the app keeps its own list of recent sessions).

## Context

A beta tester said on 2026-09-29: "It starts, but first it asks me for the folder and it does not open anything. It is not intuitive." At launch with no session, the app showed a bare `NSOpenPanel` (0014, "Active recordings"). A first-time user has no session, so every item in it is dimmed. File > New Session showed an `NSSavePanel` that asked for a name and a folder first.

Research: `docs/research/startup.md`. No reference app shows only a bare Open panel at launch by default. Xcode and IntelliJ show a start window with New, Open, and a list of recent projects. Logic and GarageBand show a Project Chooser for File > New too. GarageBand saves new projects in `~/Music/GarageBand`. An expert panel of the run (`.scratchpads/runs/2026-09-30-start-window/panel-startup.md`) compared a start window, a project chooser, a reopen of the last session, and an untitled session. It chose the start window.

Probes and research (`docs/research/startup.md` section 6):

- S6 (macOS 15.7.9, a `swiftc` CLI process). A Return key-down runs `TextField.onSubmit` when the name field has focus. `@FocusState` sets the first responder also in a window that is not key. A button with `.keyboardShortcut(.defaultAction)` takes Return before the focused control in both focus states.
- S9 (research, not probed). The Apple docs list Desktop, Documents, Downloads, iCloud Drive, network volumes, and removable volumes as protected places, and no key for the Music folder. Inference: the first write in `~/Music/Dirigible` shows no permission prompt.
- S1 was not run, because this record does not take a SwiftUI `Window` scene. S2, S3, S5, and S7 run on the built app in the verify phase of the run.

## Decision

**Owner.** The start window is an AppKit `NSWindow` with an `NSHostingController` of one SwiftUI view, the same shape as the session windows of 0014. `AppDelegate` owns it in one optional property, `start`, next to the registry of session windows. It is not in the registry, it is not an `UndoRoutingWindow`, and it is not an `NSPanel`. So plain keys (Space, J, K, L) go to its text and never to a transport. It is not restorable, and a close releases it: each show makes a new window when none is open, and brings the open one to the front otherwise.

Inference from the SDK: on macOS 14, a SwiftUI `Window` scene presents at every launch, also at a Finder open of a package, because `.defaultLaunchBehavior(.suppressed)` is macOS 15 only. The launch rules below need the app delegate to decide, and the app delegate already decides for the session windows.

**When it shows.** One method, `showStart(focus:)`, is the path of each trigger:

| Trigger | Condition |
|---|---|
| Launch | After the open events and the reopen of the active-recordings list, when no session window opened and no open event waits. |
| Dock click (`applicationShouldHandleReopen`) | No session window. |
| Close of the last session window | The registry becomes empty. |
| File > New Session (Command-N) | Always. The focus goes to the name field. |
| Window > Start Window (Shift-Command-1) | Always, also while a session window is open. |

`showStart` does nothing while the app terminates. `applicationShouldTerminate` sets a `terminating` flag as its first step, and its two cancel paths clear it. Every Quit (Command-Q, Stop and Quit, a log-out) comes through `applicationShouldTerminate`. `showStart` also does nothing when the app delegate has no default folder: the test init has none, so the tests that close their last window see no start window.

**When it closes.** Each open of a session window closes it: an open from the start window, File > Open, Open Recent, a Finder open, and an open of a package that is already open. `open(_:created:)` closes it after it resolves the key and before it returns an existing window. The close is `NSWindow.close()`, so the window delegate clears `start`. While a Create runs, a row open does nothing, and `windowShouldClose` refuses the close button and Command-W (code gate 1, item 4). `close()` does not ask `windowShouldClose`, so the open of the new session still closes the window.

**New Session.** The start window has the New Session form: a name, the folder, and Create. The save panel of New Session goes. Create calls `createSession(at:)`, which calls `Studio.create` (0014, "New session"). So the package is on disk before its window opens.

**Default folder.** `~/Music/Dirigible`. The app makes only that folder, one level, and only at a Create in it. It never makes a folder that the user chose.

**Preference key.** `session.folder` holds the folder of new sessions as a `String`, an absolute path. Change… writes it with the path of the chosen folder. The app reads it at one place: a value that starts with "/" is the folder; any other value, or no value, gives the default folder. The key never changes its meaning or its type (0024 P11). The app is not sandboxed, so a path is enough; no bookmark.

**Recent sessions.** The key `recent.sessions` holds the recent sessions as an array of `String`, each an absolute path, the newest first, 10 at most, with no path two times. Each open of a session window puts its path first. A move of an open session that the registry follows (0014) puts the new path in place of the old path, with no path two times (code gate 1, item 2). File > Open Recent > Clear Menu empties the key and the list of `NSDocumentController`. The app never drops a path by itself, because the existence check cannot tell a denied path from a missing one (code gate 1, items 1 and 3). The app reads the key once, at launch: it keeps each value that starts with "/" and drops any other value. The key never changes its meaning or its type. `AppDelegate.recent` is the one source of the start window list and of File > Open Recent. The app still calls `NSDocumentController.noteNewRecentDocumentURL` for the Dock menu and Apple menu > Recent Items, but it does not read `recentDocumentURLs`. Reason (run triage, macOS 15.7.9): the recent list of `NSDocumentController` belongs to the designated requirement of the app. For an ad-hoc signature that is the CDHash, so each new build (and each update from the ad-hoc DMG) starts with an empty list and replaces the stored list. The app preferences belong to the bundle ID and stay.

**Name.** A name is not empty, has no "/" or ":", does not start with ".", and is 245 UTF-8 bytes or less (255 bytes of a file name less the 10 bytes of ".dirigible"). Create is off for a refused name.

**Return.** Return acts on the control that has focus. In the name field, `onSubmit` runs Create. In the recent list, `onKeyPress(.return)` opens the selected session. Create is not a default button (S6). Apple documents both for macOS 14.0 and later. The `primaryAction` of `contextMenu(forSelectionType:menu:primaryAction:)` opens the row at a double-click. It has no event filter, so each input that runs it opens the row, also an input with no mouse event. The list also runs it on Return when no view takes the key. `onKeyPress` returns `.handled`, so a real Return runs only `onKeyPress` (probe M4). One input has one path. Return in the list and the initial focus are not checked on macOS 14 hardware (no macOS 14 Mac). A later run with one checks them.

**No state restoration and no command.** The start window does not restore. The active-recordings reopen stays: it is recovery, not restoration. The `dirigible` command-line tool gets no command (0011): the start window is app chrome, `dirigible create <path>` already makes a package, and the default folder is an app preference.

## Consequences

- 0014 gets an amended line: the launch and a Dock click with no session window show the start window, not the Open panel; New Session shows the start window, not a save panel.
- 0014 gets a second amended line: Open Recent reads the list of the app preferences (`recent.sessions`), not `recentDocumentURLs`.
- The strings use the area `start`, and the menu item uses `menu.window.start`. The area list of 0010 is examples, so 0010 needs no amended line.
- `AppDelegate(recordings:peakCache:defaults:defaultFolder:)` takes the default folder. Nil gives no start window. The app passes `~/Music/Dirigible`.
- A new user sees the start window at the first launch. A returning user presses Return to open the first recent session.
- A Finder open at launch shows only the session window, because the open events come before the launch check (0014 P7).

## Alternatives considered

- **A SwiftUI `Window` scene.** Rejected: on macOS 14 it presents at every launch, also at a Finder open (inference from the SDK; `.defaultLaunchBehavior` is macOS 15 only), and the launch rules would be split between the scene and the app delegate.
- **A launcher object with a pure state table of the start window.** `AppDelegate` would forward each event (launch, reopen, last close, open, quit) to it. Rejected for now: `showStart` with two guards is one path for five triggers, and the extra type moves no rule out of `AppDelegate`, which still owns the registry that each rule reads.
- **The key stores the folder of the last session that Create made.** Rejected: the folder then changes with no act of the user, and the key would get its value from two places. Change… is the one writer.
- **A project chooser with templates (Logic, GarageBand).** Deferred: Dirigible has no templates yet (F06, F63). The start window can grow into it.
- **Reopen the last session at launch (Final Cut Pro, REAPER).** Deferred: it fails at the first launch and opens a session from an unplugged disk as an error. A later setting can add it.
- **An untitled session in a temporary folder (Hindenburg, Audacity).** Rejected: Dirigible has no Save command (0014), so the session would need a move of a package that holds a lock and open capture files.
- **Keep the save panel for Command-N.** Rejected: two forms for one action. The start window form has the name filled in and the folder shown.
