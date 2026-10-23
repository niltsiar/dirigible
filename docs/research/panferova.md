# Research: Natalia Panferova and Nil Coalescing, for SwiftUI on macOS agent rules

Date: 2026-10-01

Method: WebSearch and WebFetch. WebFetch gives summaries from a small model, so every rule below is "from summary", not read on the raw page. Books were not read at all. Checkable means a reviewer can decide yes or no from the diff.

## Findings

### 1. AI-coding material by her
- Only SwiftFairy (paid MCP reviewer, out of scope, see swiftfairy.md). Launch post 25 Sep 2026: https://nilcoalescing.com/blog/IntroducingSwiftFairy
- The blog list (59 posts, fetched from the macOS tag page) holds no other agent, rules, or skill post. Talks page lists no AI-coding talk. Not verified: YouTube and podcast bodies.
- Her books are the real source of "rules for agents". They are paid (below).

### 2. Free articles with checkable rules (macOS or core SwiftUI)
Fetched and summarized:
- Menu commands and focus: https://nilcoalescing.com/blog/ProvidingTheCurrentDocumentToMenuCommands/
- Focused window: https://nilcoalescing.com/blog/DetectFocusedWindowOnMacOS (`appearsActive` replaces `controlActiveState`)
- Scene types: https://nilcoalescing.com/blog/ScenesTypesInASwiftUIMacApp
- openWindow: https://nilcoalescing.com/blog/ProgrammaticallyOpenANewWindowInSwiftUIOnMacOS
- Toolbar styles: https://nilcoalescing.com/blog/AGuideToMacOSToolbarStylesInSwiftUI
- Modifier keys: https://nilcoalescing.com/blog/RespondingToModifierKeys
- Undo: https://nilcoalescing.com/blog/HandlingUndoAndRedoInSwiftUI (2020, old; check against current API)
- ForEach in lazy containers: https://nilcoalescing.com/blog/DiagnosingForEachPerformanceIssuesInSwiftUILazyContainers
- Recursive updates, AppKit view in SwiftUI: https://nilcoalescing.com/blog/TrackingValueSourcesToPreventRecursiveSwiftUIUpdates
- Custom lazy list, AppKit controls: https://nilcoalescing.com/blog/CustomLazyListInSwiftUI
- Canvas responsiveness: https://nilcoalescing.com/blog/KeepingCanvasInteractionsResponsiveWithFrameReprojection (GPU and Metal; weak fit, our timeline is AppKit)
- Book update note (data flow, identity): https://nilcoalescing.com/blog/TheSwiftUIWayUpdateJuly2026

Not read, titles only: Inspectors in SwiftUI, Custom scenes, Menu bar utility, Customizing window background, Programmatically hide and show sidebar, Focus-based navigation, Tracking hover location, List selection for navigation on macOS. Candidates for a later pass.

Gaps: no article on Observation basics, localization, or accessibility among the 59 titles. Those are in her books and talks (an accessibility video exists: https://www.youtube.com/watch?v=CEZbwcv60MA, not watched). Our audio-specific and AppKit-timeline needs are not covered by her.

Version caution: the July 2026 update mentions `@State` becoming a macro in Xcode 27. Our ceiling is Xcode 26.3 (project memory). Do not copy anything that needs Xcode 27 or macOS 26-only API into a macOS 14 rule.

### 3. Books, price, licensing
- https://books.nilcoalescing.com/: SwiftUI Fundamentals $35, The SwiftUI Way $35 (patterns and anti-patterns for production apps, covers data flow, view updates, lists, accessibility, platform conventions; no sample seen), Swift Charts Beyond the Basics $35, Swift Gems $35, Integrating SwiftUI into UIKit Apps $40 (mostly UIKit; our need is AppKit, so low value). Bundles exist, price not read.
- Worth it? Only "The SwiftUI Way" at $35 is plausibly worth it, as input for one human-reviewed rule list. It says nothing about macOS audio or AppKit timelines. Not clearly worth it today; defer until a concrete SwiftUI bug class repeats in the ledger. Never paste book text into the repo or into agent context (copyright and sold license).
- Blog: copyrighted. Code samples are MIT in https://github.com/nilcoalescing/SwiftUI-Code-Examples (per earlier research). We write our own rules with a link each. Rules (facts about API behavior) are not copyrightable; wording is.
- A skill built from these links is feasible but small: about 20 rules fit in under 150 lines.

### 4. Network not yet covered
All from search snippets, none verified as AI-coding people:
- Leo Dion (EmpowerApps podcast host, Mar 2025 episode on SwiftUI Fundamentals).
- Jeroen Leenarts (AppForce1 podcast).
- Walid Sassi, Jason Dubon (podcast hosts; Swift Academy podcast is a search hit).
- John Sundell (Swift by Sundell ep. 118, Nov 2022).
- SwiftToolkit.dev "Dev Conversations #7" with her: https://www.swifttoolkit.dev/posts/dc-natalia
- Matthaus Woolard (hishnash), co-author of SwiftFairy; no agent repos.
None publishes agent skills that I found. Low value; no follow-up recommended.

## Candidate rules (our wording, STE; source link each; all unverified beyond summaries)

1. Use `focusedSceneValue` for data that menu commands need. Use `focusedValue` only when a focused view must supply it. https://nilcoalescing.com/blog/ProvidingTheCurrentDocumentToMenuCommands/
2. Define a custom focus key as a `FocusedValueKey` with a `Value` type and an extension of `FocusedValues`. Same source.
3. Read focused data in a `Commands` type with `@FocusedBinding` or `@FocusedValue`. Disable the command when the value is nil. Same source.
4. Put commands in a separate `Commands` type. Do not put logic in the `App` body. Same source.
5. Read window focus with `@Environment(\.appearsActive)`. Do not use `controlActiveState` (deprecated from macOS 15). https://nilcoalescing.com/blog/DetectFocusedWindowOnMacOS
6. Use `Window` for a single-instance window. Use `WindowGroup` when many windows are valid. https://nilcoalescing.com/blog/ScenesTypesInASwiftUIMacApp
7. Use the `Settings` scene for preferences. Do not make a custom preferences window. Same source.
8. Pass a `Hashable` and `Codable` value to `openWindow`. Pass an ID, not a full model. https://nilcoalescing.com/blog/ProgrammaticallyOpenANewWindowInSwiftUIOnMacOS
9. Expect SwiftUI to reuse the window for an equal value. Do not code a second check. Same source.
10. Use `onModifierKeysChanged` only on macOS 15 or later. On macOS 14, use an AppKit path. https://nilcoalescing.com/blog/RespondingToModifierKeys
11. Set the toolbar look with `windowToolbarStyle`. Remove the title with `toolbar(removing: .title)`, not by hiding the title bar. https://nilcoalescing.com/blog/AGuideToMacOSToolbarStylesInSwiftUI
12. Gate any toolbar or window API that needs macOS 15 or 26 with `#available`. Same source.
13. Filter a collection before `ForEach`, not inside the closure. https://nilcoalescing.com/blog/DiagnosingForEachPerformanceIssuesInSwiftUILazyContainers
14. Make each `ForEach` element return a constant number of views. Wrap conditional content in a stack. Same source.
15. Run the app once with the launch argument `-LogForEachSlowPath YES` after a change to a lazy list. Same source.
16. Do not use a full `Hashable` value as `ForEach` identity when other fields change. Use a stable ID. https://nilcoalescing.com/blog/TheSwiftUIWayUpdateJuly2026
17. Pass shared actions, config, and models through the environment. Check that this causes no extra view updates. Same source.
18. In an `NSViewRepresentable`, track where an update came from. Do not write a model value back to the view if the view made it. Use a transaction value, not a string compare. https://nilcoalescing.com/blog/TrackingValueSourcesToPreventRecursiveSwiftUIUpdates
19. Do not compare a large value in `updateNSView` on every update. Compare a cheap identity. Same source.
20. Treat recycled lazy-row views as holding old `@State`. Reset row state when the row ID changes. https://nilcoalescing.com/blog/CustomLazyListInSwiftUI
21. For lists over about 1,000 rows with fixed height, test the built-in `List` first. Use a custom lazy layout only after a measured problem. Same source.
22. While a user drags, draw a cheap version and keep one pending render. Draw the full version on release. https://nilcoalescing.com/blog/KeepingCanvasInteractionsResponsiveWithFrameReprojection
23. Use `@Environment(\.undoManager)`. A text field already has undo; do not wrap it. https://nilcoalescing.com/blog/HandlingUndoAndRedoInSwiftUI
24. Register undo with a class target, and register the inverse inside the undo block for redo. Same source.
25. Clear `UserDefaults` for the app domain when you test first-launch behavior. https://nilcoalescing.com/blog/ClearingUserDefaultsDuringmacOSAppDevelopment (title only; body not read)

Fit to this repo: 1-9 and 11-12 match the SwiftUI shell, menus, and windows. 18-19 and 22 match the AppKit timeline interop. 13-17 and 20-21 match any SwiftUI list (tracks, pool). Several rules may already exist in `.claude/` skills or the UI panel prompts; I did not diff them.

## Recommendations (at most 4)

1. File: new `.claude/skills/swiftui-macos-rules/SKILL.md` (about 100 lines). Change: write rules 1-9, 11-14, 16, 18-20 in our words, one source link each, plus the line "check the macOS 14 availability of each API". Why: a short checklist the UI panel and code-quality lens can cite. Risk: summary-only sourcing; two or three rules may be wrong. Check each against Apple docs or a probe before merge. Also check for overlap with existing skills first.
2. File: `.claude/agents/code-quality-reviewer.md`. Change: add one line that points to the skill for any diff that touches `Sources/*App*` or a SwiftUI view. Why: loads the rules only when needed. Risk: more load for every review if the pointer is not scoped.
3. File: the backlog (a wiki item). Change: add "read Panferova posts Inspectors, Custom scenes, Hide and show sidebar, Focus-based navigation; verify rules 5, 10, 16 on raw pages". Why: closes the unverified part cheaply. Risk: none.
4. Do not buy now. If a SwiftUI view-update or identity bug repeats in the ledger, then buy "The SwiftUI Way" ($35), read it as a human, and write own rules. Risk of not buying: agents miss deeper anti-patterns; the free posts cover only a slice.

## Not verified
- All article content is from WebFetch summaries, not raw text. Code details (for example exact modifier names) need a check.
- Book contents, bundle prices, and sample availability.
- Any AI-coding talk or post outside the blog index.
- Whether our existing skills already hold these rules.

## Sources
- https://nilcoalescing.com/blog/ and https://nilcoalescing.com/tags/macos/
- https://nilcoalescing.com/blog/IntroducingSwiftFairy
- https://books.nilcoalescing.com/
- https://nilcoalescing.com/blog/TheSwiftUIWayReleaseAnnouncement
- https://nilcoalescing.com/blog/TheSwiftUIWayUpdateJuly2026
- Article URLs listed in Findings 2 and in each rule
- https://nilcoalescing.com/talks/
- https://www.swifttoolkit.dev/posts/dc-natalia
- https://github.com/nilcoalescing/SwiftUI-Code-Examples
