# Startup: what the app shows at launch, and how other apps start

Date: 2026-09-29

## Scope

A beta tester (2026-09-29) said: "It starts, but first it asks me for the folder and it does not open anything. It is not intuitive." The tester had to cancel the panel and find File > New. This document records what Dirigible does at launch today, how 11 reference apps start, and which macOS 14 and 15 APIs a start window can use.

Marks: "(unconfirmed)" means that no primary source was found. "Inference:" is our reading. "[SDK]" is the Xcode 26.3 SDK (macOS 26.2 SDK) on this Mac: `SwiftUI.swiftmodule/arm64e-apple-macos.swiftinterface` and the AppKit headers, read on 2026-09-29.

## 1. What happens today

The app is not a `DocumentGroup` app. Decision 0014 gives an app with only a `Settings` scene and one AppKit window per package, with no `NSDocument` subclass. So the `NSDocumentController` untitled-document path, `applicationShouldOpenUntitledFile`, and the iCloud "app-centric" open panel do not apply. The panel that the tester saw is our own panel.

| Step | Code | What the user sees |
|---|---|---|
| Launch, no file | `Sources/DirigibleApp/AppDelegate.swift:213-219` | The app opens each package of the active-recordings list (crash recovery, 0004). Then `if windows.isEmpty && openEvents == 0 { showOpenPanel() }` (line 218). |
| The panel | `AppDelegate.swift:157-166` | A plain `NSOpenPanel` that accepts only the `.dirigible` package type. It has no New button and no text. A first-time user has no session, so every item in it is dimmed. Inference: this is "it asks me for the folder". |
| Dock click, no window | `AppDelegate.swift:222-225` | The same Open panel. |
| Last window closes | `AppDelegate.swift:227` | The app stays open with no window (only the menu bar). |
| File > New Session (Command-N) | `AppDelegate.swift:170-180`, `DirigibleApp.swift:17` | An `NSSavePanel` asks for a name and a folder first. Then `Studio.create` makes the package on disk (`AppDelegate.swift:183-193`) and a window opens. |
| File > Open, Open Recent | `DirigibleApp.swift:18-23`, `AppDelegate.swift:13, 87-88` | Open Recent reads `NSDocumentController.shared.recentDocumentURLs`; each open calls `noteNewRecentDocumentURL`. |
| Open from Finder | `AppDelegate.swift:203-209` | Open events come before `applicationDidFinishLaunching` (0014 P7), so no panel shows. |

The guide documents this flow: `docs/guide.md:24-28` ("Choose File > New Session", then "Type a name ..., select a folder, and click Save").

Two facts constrain a new flow:

- A session is a package on disk, and a take needs that package before it starts (AGENTS.md "No data loss"; 0004, 0012). `Studio.create` needs a URL. The app has no Save command: each change saves at once (0014). So an "untitled session in memory" has no later Save step that asks for a name.
- 0014 rejects `DocumentGroup`: its save replaces the package folder and deletes `Capture/` (0014 P1). `docs/research/document-window.md` section 5.

## 2. How other apps start

| App | First launch | Later launch | After the last window closes | New project: where saved |
|---|---|---|---|---|
| Hindenburg Journalist 1.21 | File > New "will open with an empty session with the following tracks: Speak, Interview, Ambience, Music" [HM p. 12]. What shows at launch is not documented (unconfirmed). | Autosave: "If the program should fail the last session will be recovered" [HM p. 86]. | (unconfirmed) | Preferences > Audio > "Temp Folder > Storage for temporary session files" [HM p. 75]. Save names the session later [HM p. 86]. Inference: it records an unsaved session into the temp folder. |
| Hindenburg PRO 2 | The guide lists "File - New: Create a new session", "File - Recent Session", and "Properties - Default: Save default session" [HS]. | (unconfirmed) | (unconfirmed) | (unconfirmed) |
| Logic Pro 12 | The Startup Action setting has these values: Do Nothing; Open Most Recent Project; Open Existing Project ("Shows the Open dialog"); Select a Template; Create New Empty Project; Create New Project Using Default Template; Ask ("Opens a Startup dialog, offering each of the above options") [LP-ph]. The default value is not documented (unconfirmed). | Same setting. "Open a recent project: ... In the Project Chooser, click Recent, then double-click the project" [LP-open]. | (unconfirmed) | File > New shows the Project Chooser: New Project, Recent, Live Loops Grids, Project Templates, My Templates, and a Details area with the input and output device [LP-new]. "The first time you save a new project, the Save dialog appears" [LP-save]. Autosave covers the unsaved project [LP-save]. |
| Logic Pro 9 (old manual) | The same Startup Action list, without Ask [LP9]. | | | |
| GarageBand 10.4 | File > New (Command-N) shows the Project Chooser with Project Templates and Recent, and a Details area with the input and output device [GB-new]. That the Project Chooser shows at launch is not documented in the Apple guide (unconfirmed; secondary sources say so [MW]). | (unconfirmed) | (unconfirmed) | "The first time you save a new project, the Save dialog appears." "By default, projects are saved in the GarageBand subfolder in the Music folder" [GB-new]. |
| Final Cut Pro | (unconfirmed) | "To open specific libraries when you open Final Cut Pro, Option-click the Final Cut Pro app icon in the Dock, then select one or more libraries in the list and click Choose" [FCP-lib]. Inference: by default it opens the libraries of the last run. | The app keeps its single main window. | A library is a bundle on disk; File > New > Library asks for a location [FCP-lib]. |
| Adobe Audition | The Adobe help page returned HTTP 403 (unconfirmed). File > New > Multitrack Session asks for a session name, a folder location, a template, and a sample rate (search excerpt, unconfirmed). | | | |
| Audacity 3 | An empty project window (unconfirmed). | "Audacity will attempt automatic recovery of projects (open and unsaved) the next time you relaunch" [AU-proj]. | | The temporary directory "is used whenever there is audio data that has never been saved as an Audacity project" [AU-dir]. |
| REAPER | "By default, REAPER opens with the last used project" (search excerpt of the user guide, unconfirmed). Preferences > General > "Open project(s) on startup": last active project, all previous project tabs, new project, or prompt. The prompt window lists last active project, new project, templates, and recent projects [RP]. | | | |
| Descript | The Drive view "appears when you ... open the desktop app": Home ("Start new projects from templates"), Recents ("sorted by last viewed"), and a New project button [DS]. | Same. | | Cloud drive. |
| Riverside | A web dashboard: the list of studios, a button that creates a studio, and View Recordings per studio (secondary [RV]). | Same. | | Cloud. |
| Xcode | The "Welcome to Xcode" window: create a project, clone, open, and a list of recent projects [XC-new], [KO]. "Show this window when Xcode launches"; Window > Welcome to Xcode, Shift-Command-1 [KO]. | A project that was open at quit reopens, and then the welcome window does not show (secondary [KO-s]). | (unconfirmed) | The new-project sheet asks for a location at the end [XC-new]. |
| IntelliJ IDEA | The Welcome screen: New Project, Open, Get from VCS, and a list of recent projects with search, groups, and remove [IJ-open]. | "If you quit the IDE having multiple opened projects, they all will be reopened the next time"; the "Reopen projects on startup" check box turns this off [IJ-open], [IJ-sys]. | The Welcome screen shows (inference from [IJ-open]). | "Default project directory ... IntelliJ IDEA suggests this directory when creating new projects" [IJ-sys]. |

Findings:

1. No reference app shows a bare Open panel as the only thing at launch by default. Logic offers it only as one Startup Action value.
2. Two patterns exist. The chooser pattern (Logic "Ask" and Project Chooser, GarageBand, Xcode, IntelliJ, REAPER prompt, Descript) shows New, Open, and Recent in one window. The resume pattern (Logic "Open Most Recent Project", FCP, REAPER default, IntelliJ, Xcode) reopens the last work. The pro apps offer both, and a setting selects one.
3. The chooser and the New form are often one window: Logic and GarageBand show the Project Chooser for File > New too.
4. Apps with a Save command (Logic, GarageBand, Audacity, Hindenburg) record an unsaved project into a default or temp folder and ask for the name at the first Save. Dirigible has no Save command (0014).
5. A default folder is common: `~/Music/GarageBand` [GB-new], `~/Music/Logic` (secondary), and the IntelliJ default project directory [IJ-sys].

## 3. Apple guidance

- HIG Launching: "Launch instantly." "Restore the previous state when your app restarts so people can continue where they left off" [HIG-launch].
- HIG Onboarding: "Teach through interactivity." "Postpone nonessential setup flows or customization steps. Provide reasonable default settings so most people can immediately start interacting" [HIG-onb].
- `applicationShouldHandleReopen(_:hasVisibleWindows:)`: the Dock or Finder sends it when the running app is activated again. "If there are none [visible windows], it goes through the standard untitled document creation." "Miniaturized windows ... are considered visible" [AK-reopen].
- `NSShowAppCentricOpenPanelInsteadOfUntitledFile` is a user default that stops the open panel at launch of iCloud document apps such as TextEdit [MT]. It is not in the SDK headers [SDK]. It applies to `NSDocumentController` apps only, so not to Dirigible.
- The system setting "Close windows when quitting an application" maps to the `NSQuitAlwaysKeepsWindows` default, and the checkbox is on by default (secondary [MD]; unconfirmed). AppKit window restoration follows it.

## 4. SwiftUI and AppKit APIs for a start window [SDK]

| API | macOS | Note |
|---|---|---|
| `DocumentGroupLaunchScene`, `DocumentLaunchView` | unavailable | `@available(macOS, unavailable)`: iOS 18 and visionOS 2 only. |
| `Window` scene | 13 | A single-instance window scene. |
| `openWindow`, `OpenWindowAction` | 13 | |
| `dismissWindow` | 14 | |
| `openDocument`, `newDocument` | 13 | For `DocumentGroup` documents. Not usable without `DocumentGroup`. |
| `NewDocumentButton` | 15 | `DocumentGroup` only. |
| `.defaultLaunchBehavior(.presented / .suppressed)` | 15 | "Used to define if a scene is shown on application launch in the absence of any previously saved state." On macOS it also selects "which scene is presented when clicking on the icon of a running application with no visible windows" [SUI-dlb]. The default is "automatic": the first scene of the app presents itself when no other scene did [SUI-dlb]. |
| `.restorationBehavior(.disabled)` | 15 | |
| `.windowManagerRole(.principal / .associated)` | 15 | |
| `NSWindow.isRestorable`, `restorationClass`, `NSWindowRestoration` | 10.7 | The AppKit restoration path. `NSApplicationDidFinishRestoringWindowsNotification` posts between will-finish and did-finish launching [SDK `NSWindowRestoration.h`]. |
| `NSDocumentController.shared.recentDocumentURLs`, `noteNewRecentDocumentURL` | 10.x | "You can use this even in non-NSDocument-based applications" [SDK `NSDocumentController.h:235`]. Already used. |

Inference: on macOS 14, a SwiftUI `Window` scene placed before `Settings` presents itself at every launch, also when Finder opens a package, because `.defaultLaunchBehavior(.suppressed)` needs macOS 15. An AppKit window that `AppDelegate` shows (the same shape as the session windows of 0014) works the same on 14 and 15, and the existing launch logic decides when it shows. This inference needs probe S1.

## 5. Probes that a run needs

- S1. SwiftUI `Window` scene plus `Settings` on macOS 14: does the window present at a Finder open of a package, and at a Dock click with no window? Compare with macOS 15 and `.defaultLaunchBehavior(.suppressed)`. Only needed if the run picks a SwiftUI scene.
- S2. `applicationShouldHandleReopen` when the only window is the start window, and when it is minimized.
- S3. `recentDocumentURLs` after the package is moved, renamed, or on an unplugged disk: does AppKit drop the entry, and does `FileManager.fileExists` block on a hung volume (read it off the main actor, as `listedAtLaunch` does).
- S4. `UserDefaults.standard.bool(forKey: "NSQuitAlwaysKeepsWindows")` on a clean user account on macOS 14 and 15 (only if the run adds reopen-at-launch).
- S5. `Studio.create` into a new default folder (`~/Music/Dirigible`): the folder does not exist; the folder has a deny ACL (0014 P15); the disk is full.
- S6. Return key in a window with a name field (default button Create) and a recent list: which action runs.
- S8. Quit with one session window, and Stop and Quit during a take: the last-close path must not show the start window.
- S7. Spanish: the start window strings with `-AppleLanguages "(es)"` (0010), and the longest Spanish label in the fixed-width layout.

## 6. Probes and checks of run 2026-09-30-start-window

S6 ran on 2026-09-30 in a `swiftc` CLI process on macOS 15.7.9, not in the test runner and not in the app. A probe proves only the objects that it ran with. The run folder `.scratchpads/runs/2026-09-30-start-window/probe/s6/` has the source and the logs. The view has a `TextField` with `onSubmit`, a `List` with a selection and `contextMenu(forSelectionType:menu:primaryAction:)`, and `@FocusState`, in an `NSHostingController` of an `NSWindow`. The probe sends a Return key-down with `window.performKeyEquivalent`, then `window.sendEvent`.

| Probe | Result (macOS 15.7.9, CLI process) |
|---|---|
| S6b, focus in the name field | `TextField.onSubmit` runs. |
| S6b, focus in the list | The `primaryAction` of the context menu runs on the selected row. |
| S6c, window not key | `@FocusState` sets the first responder: the field editor for the name field, `SwiftUIOutlineListView` for the list. Return still reaches the action. |
| S6, default button | With `Button.keyboardShortcut(.defaultAction)`, `performKeyEquivalent` takes Return in both focus states. Neither `onSubmit` nor `primaryAction` runs. |

Inference: a default button in the start window takes Return before the list sees it. So Return must act on the control that has focus, and Create must not be a default button.

The Apple docs name `primaryAction` only for double-click on macOS: "a double click performs the primary action" [SUI-ctx]. They document `onKeyPress(_:action:)` for macOS 14.0 and later: "Performs an action if the user presses a key on a hardware keyboard while the view has focus" [SUI-kp]. S6 did not probe `onKeyPress`. No macOS 14 Mac was available.

S9 was researched, not probed. The question: does the first write in `~/Music/Dirigible` show a permission prompt? `scripts/probe.sh` refuses a write outside its folder, and TCC gives a write from a CLI process to the terminal, not to the app. The Apple Platform Security guide lists the protected places: "Desktop, Documents, Downloads, network volumes, and removable volumes", and iCloud Drive [PS-files]. The protected-resources list has `NSDesktopFolderUsageDescription`, `NSDocumentsFolderUsageDescription`, and `NSDownloadsFolderUsageDescription`, and no key for the Music folder [PR]. `NSAppleMusicUsageDescription` is about access to the media library, not about a file write [PR]. Inference: a write in `~/Music` shows no prompt, and a write in `~/Documents` does (macOS 10.15 and later). A check on the built app confirms it.

## Sources

- [HM] Hindenburg Journalist 1.21 user guide (Hindenburg Systems), pp. 12, 75, 86, 98: https://www.willyurman.com/teaching/handouts/Hindenburg_Journalist.pdf (text read from the PDF streams on 2026-09-29)
- [HS] Hindenburg PRO guides: https://hindenburg.com/academy/guides/guides-hindenburg-pro/
- [LP-ph] Project Handling settings in Logic Pro for Mac (12.3): https://support.apple.com/guide/logicpro/project-handling-settings-lgcp43defb63/mac
- [LP-open] Open Logic Pro for Mac projects: https://support.apple.com/guide/logicpro/open-projects-lgcpce1280f1/mac
- [LP-new] Create Logic Pro for Mac projects: https://support.apple.com/guide/logicpro/create-projects-lgcpce0f09d9/mac
- [LP-save] Save Logic Pro for Mac projects: https://support.apple.com/guide/logicpro/save-projects-lgcpce128e82/mac
- [LP9] Logic Pro 9 manual, Opening and Creating Projects Automatically: https://help.apple.com/logicpro/mac/9.1.6/en/logicpro/usermanual/chapter_7_section_4.html
- [GB-new] Create and save projects in GarageBand on Mac (10.4.14): https://support.apple.com/guide/garageband/create-save-and-delete-projects-gbndd0893c9b/mac
- [MW] Macworld, Getting started with GarageBand (secondary): https://www.macworld.com/article/222639/getting-started-with-garageband.html
- [FCP-lib] Open and close libraries in Final Cut Pro for Mac: https://support.apple.com/guide/final-cut-pro/open-and-close-libraries-ver217d6e77d/mac
- [AU-proj] Audacity Manual, Managing Audacity Projects: https://manual.audacityteam.org/man/audacity_projects.html
- [AU-dir] Audacity Manual, Directories Preferences: https://manual.audacityteam.org/man/directories_preferences.html
- [RP] REAPER user guide (search excerpts; the PDF did not load): https://www.reaper.fm/userguide.php and the Cockos forum thread "REAPER Choose Project(s)": https://forum.cockos.com/archive/index.php/t-166845.html
- [DS] Descript Help, Drive view: https://help.descript.com/descript-tour/drive-view
- [RV] Riverside, Organize your studios and projects (HTTP 403; search excerpt): https://support.riverside.com/hc/en-us/articles/5734412867485-Organize-your-studios-and-projects
- [XC-new] Xcode Help, Create a project: https://help.apple.com/xcode/mac/current/en.lproj/dev07db0e578.html
- [KO] Kodeco, macOS Apprentice chapter 1 (secondary): https://www.kodeco.com/books/macos-apprentice/v1.0/chapters/1-introducing-xcode
- [KO-s] InformIT, Kicking the Tires of Xcode 5 (secondary, search excerpt): https://www.informit.com/articles/article.aspx?p=2211693
- [IJ-open] IntelliJ IDEA, Open, move, and close projects: https://www.jetbrains.com/help/idea/open-close-and-move-projects.html
- [IJ-sys] IntelliJ IDEA, System settings: https://www.jetbrains.com/help/idea/system-settings.html
- [HIG-launch] Apple HIG, Launching: https://developer.apple.com/design/human-interface-guidelines/launching
- [HIG-onb] Apple HIG, Onboarding: https://developer.apple.com/design/human-interface-guidelines/onboarding
- [AK-reopen] `applicationShouldHandleReopen(_:hasVisibleWindows:)`: https://developer.apple.com/documentation/appkit/nsapplicationdelegate/applicationshouldhandlereopen(_:hasvisiblewindows:)
- [SUI-dlb] `defaultLaunchBehavior(_:)`: https://developer.apple.com/documentation/swiftui/scene/defaultlaunchbehavior(_:)
- [MT] Michael Tsai, Making TextEdit Create an Untitled Document at Launch (2020, secondary): https://mjtsai.com/blog/2020/12/10/making-textedit-create-an-untitled-document-at-launch/
- [MD] macos-defaults.com, NSQuitAlwaysKeepsWindows (secondary): https://macos-defaults.com/misc/nsquitalwayskeepwindows.html
- [SDK] Xcode 26.3, MacOSX.sdk 26.2: `SwiftUI.swiftmodule/arm64e-apple-macos.swiftinterface` (lines 270-276, 3027, 3128-3165, 4538-4553, 9362-9378, 10420-10425, 23598-23604, 24936-24940, 25610-25615), `AppKit.framework/Headers/NSApplication.h:417-423`, `NSDocumentController.h:235-241`, `NSWindowRestoration.h:29-61`.
- [PS-files] Apple Platform Security, Controlling app access to files in macOS: https://support.apple.com/guide/security/controlling-app-access-to-files-secddd1d86a6/web
- [PR] Apple Developer, Protected resources: https://developer.apple.com/documentation/bundleresources/protected-resources
- [SUI-ctx] `contextMenu(forSelectionType:menu:primaryAction:)`: https://developer.apple.com/documentation/swiftui/view/contextmenu(forselectiontype:menu:primaryaction:)
- [SUI-kp] `onKeyPress(_:action:)`: https://developer.apple.com/documentation/swiftui/view/onkeypress(_:action:)
- Probe S6: `.scratchpads/runs/2026-09-30-start-window/probe/s6/` (`main.swift` and the `run-*.log` files; macOS 15.7.9, Swift 6.2.4, a `swiftc` CLI process).
- Repo: `Sources/DirigibleApp/AppDelegate.swift`, `Sources/DirigibleApp/DirigibleApp.swift`, `docs/decisions/0014-session-window.md`, `docs/research/document-window.md`, `docs/guide.md`.
