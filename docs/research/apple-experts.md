# Research: people and resources for the Dirigible agent workflow

Date: 2026-10-01

Scope: a curated map of the people and resources whose knowledge matters most for this app. The UI expert panel, the review lenses, the research skill, and future skills can use it. Access date for all URLs: 2026-10-01. I read most pages with WebFetch, which summarizes a page. Apple doc titles and abstracts came from the DocC JSON endpoint. WWDC titles came from the page `<title>`. "Not verified" means a search snippet only, or a failed fetch.

Earlier files cover these sources. Do not repeat them: Paul Hudson, Antoine van der Lee, Thomas Ricouard, and Point-Free (swift-mac.md); pchelnikov Swift-6-Agent-Skill and the macOS skill repos (swiftfairy.md); Natalia Panferova and Nil Coalescing (panferova.md).

Agent skills or rules: none of the picks below publish agent skills. One exception: NetNewsWire has a `CLAUDE.md` (MIT). It holds build commands, a module map, and five style rules. One rule is useful here: "Just because unit tests pass doesn't mean a given bug is fixed."

## 1. SwiftUI on macOS and Mac app design

| Pick | Use in this repo | URLs | Cost |
|---|---|---|---|
| Chris Eidhof, Florian Kugler (objc.io) | Layout and view-update model of the SwiftUI shell. Field Guide for layout questions. | https://www.swiftuifieldguide.com/, https://chris.eidhof.nl/, https://www.objc.io/books/ | Field Guide free. "Thinking in SwiftUI" $39. Swift Talk $15 a month, archive only (no new episodes). |
| Sarah Reichelt (TrozWare) | Mac-only SwiftUI: menus, settings, windows, document apps. Her "macOS Apprentice" 3rd ed. covers Swift 6 and macOS 26. | https://troz.net/ | Blog free. Books paid (price not read). |
| Majid Jabrayilov | Weekly SwiftUI API notes. Recent: "Backporting SwiftUI APIs" (relevant for a macOS 14 floor). | https://swiftwithmajid.com/ | Free. Mostly iOS examples. |
| Apple HIG, "Designing for macOS" | Ground truth for the UI expert panel: menus, toolbars, windows, keyboard. | https://developer.apple.com/design/human-interface-guidelines/designing-for-macos | Free. Title verified, body not read. |
| Sindre Sorhus | Model for small native Mac utilities and MIT Swift packages (for example KeyboardShortcuts, 2.7k stars, SwiftUI and AppKit recorder). | https://sindresorhus.com/apps, https://github.com/sindresorhus/KeyboardShortcuts | Free code. A new dependency needs a decision record. |

Natalia Panferova is the strongest SwiftUI-on-macOS source. See panferova.md.

## 2. AppKit and classic Mac craft

| Pick | Use in this repo | URLs | Cost |
|---|---|---|---|
| Michael Tsai | Aggregator. Search his blog first for any macOS API change, bug, or Gatekeeper change. Each post links the primary sources. | https://mjtsai.com/blog/ | Free. |
| Brent Simmons, NetNewsWire | A large open-source AppKit Mac app (MIT, 10.4k stars). He moved it to Swift concurrency in 2025-2026. Read real AppKit code, not samples. | https://inessential.com/, https://github.com/Ranchero-Software/NetNewsWire | Free. Uses an Xcode project (we do not). |
| Christian Tietze | AppKit text and document patterns, architecture, and selling outside the App Store. | https://christiantietze.de/ | Blog free. Books paid ("Make Money Outside the Mac App Store", "Exploring Mac App Development Strategies"). |
| Jeff Johnson (Lap Cat Software) | macOS bugs, Gatekeeper, notarization, sandbox, keychain changes per release. Also in area 6. | https://lapcatsoftware.com/articles/ | Free. |
| Gus Mueller (Flying Meat, Acorn) | Craft of a pro document-and-canvas Mac app. Acorn is the nearest analog to a custom-drawn editor. | https://shapeof.com/ | Free. Few technical posts. |
| Daniel Jalkut (Red Sweater, MarsEdit) | Long-lived indie AppKit app. Low priority: the company blog is product news. | https://bitsplitting.org/ (site loads; content not read), https://redsweater.com/blog/ | Free. |

Steve Troughton-Smith publishes mostly Mac Catalyst samples (search only, not verified: https://github.com/steventroughtonsmith). Low fit for a pure AppKit timeline. Skip.

## 3. Swift concurrency and Swift 6

| Pick | Use in this repo | URLs | Cost |
|---|---|---|---|
| Swift Concurrency Migration Guide (swift.org) | Primary reference for data-race safety, isolation, and incremental adoption. Cite it in concurrency review findings. | https://www.swift.org/migration/documentation/migrationguide/ (page did not render; URL confirmed from the repo README), https://github.com/swiftlang/swift-migration-guide | Free, Apache-2.0. |
| Swift Evolution | Exact rules for each feature. For example SE-0466 (default actor isolation) matters for Swift 6.2. | https://www.swift.org/swift-evolution/, https://github.com/swiftlang/swift-evolution/blob/main/proposals/0466-control-default-actor-isolation.md | Free. |
| Apple WWDC sessions | "Embracing Swift concurrency" (WWDC25), "Migrate your app to Swift 6" (WWDC24), "Explore concurrency in SwiftUI" (WWDC25). | https://developer.apple.com/videos/play/wwdc2025/268/, https://developer.apple.com/videos/play/wwdc2024/10169/, https://developer.apple.com/videos/play/wwdc2025/266/ | Free. |
| Matt Massicotte | Practical isolation questions: nonisolated callbacks, protocols, libraries not built for concurrency. His ConcurrencyRecipes repo (BSD-3) now has a new maintainer and says it is not updated for Swift 6.0. Use the recipes as background only. | https://www.massicotte.org/, https://github.com/mattmassicotte/ConcurrencyRecipes | Free. Consulting paid. |
| Donny Wals | Second explainer for actors and tasks. Recent posts on agent pipelines for Apple apps. | https://www.donnywals.com/ | Blog free. "Practical Swift Concurrency" paid (price not read). |
| Holly Borla and the Swift Forums | Language team view on Swift 6 diagnostics. Read Forums threads when a compiler diagnostic is unclear. | https://forums.swift.org/c/swift-users/15 | Free. Her profile page returned 403 (not verified). |

## 4. Core Audio, real-time audio, and Mac audio apps

| Pick | Use in this repo | URLs | Cost |
|---|---|---|---|
| Apple Core Audio taps docs | Primary source for process taps. `AudioHardwareCreateProcessTap` is macOS 14.2+. `CATapDescription` is macOS 12.0+. The sample article metadata says macOS 26.0. Our floor and reasons are in decision 0006; do not derive it again. | https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps, https://developer.apple.com/documentation/coreaudio/audiohardwarecreateprocesstap(_:_:) | Free. |
| Guilherme Rambo, AudioCap | Working process-tap sample (BSD-2, macOS 14.4+). Shows `NSAudioCaptureUsageDescription` and the TCC prompt. The repo already cites it (docs/research/capture.md). | https://github.com/insidegui/AudioCap | Free. |
| Ross Bencina, "Real-time audio programming 101: time waits for nothing" | The base text for the audio-thread rules in AGENTS.md: no malloc, free, printf, mutex lock, or wait in the callback. Worst-case time, not average. | http://www.rossbencina.com/code/real-time-audio-programming-101-time-waits-for-nothing | Free. Read with curl (HTTPS refused). |
| Michael Tyson, "Four common mistakes in audio development" | Four rules: no locks, no Objective-C or Swift runtime, no allocation, no file or network I/O on the audio thread. Not verified: the site returned HTTP 500. | https://atastypixel.com/four-common-mistakes-in-audio-development/ | Free. |
| Timur Doumler, "Using locks in real-time audio processing, safely" (ADC20) | Why a lock is dangerous and which lock-free patterns replace it (atomics for one value, immutable copies for a struct). He shows some lock patterns that can be safe. AGENTS.md keeps "no locks"; cite him for the why, not to relax the rule. Not verified: timur.audio returned HTTP 500. | https://www.youtube.com/watch?v=zrWYJ6FdOFQ, https://timur.audio/using-locks-in-real-time-audio-processing-safely | Free. |
| Rogue Amoeba; Chris Liscio (SuperMegaUltraGroovy, Capo) | Product benchmarks for Mac audio. Rogue Amoeba posts list macOS audio bugs per release (for example VoIP capture in macOS 27). Liscio is the solo audio developer of Capo and FuzzMeasure; his blog has few deep DSP posts (author from search, not verified). | https://weblog.rogueamoeba.com/, https://supermegaultragroovy.com/ | Blogs free. Apps paid. |

AudioKit (MIT, 11.5k stars, on AVAudioEngine) is a good code reference for DSP. It is not a dependency candidate: AGENTS.md puts Apple frameworks first.

## 5. Performance and Instruments on macOS

| Pick | Use in this repo | URLs | Cost |
|---|---|---|---|
| Apple, "Improving app responsiveness" | Definitions of hangs and hitches. Use for timeline scroll and playback work. | https://developer.apple.com/documentation/xcode/improving-app-responsiveness | Free. |
| WWDC Instruments sessions | "Analyze hangs with Instruments" (WWDC23), "Visualize and optimize Swift concurrency" (WWDC22), "Analyze heap memory" (WWDC24), "Optimize SwiftUI performance with Instruments" (WWDC25), "Demystify SwiftUI performance" (WWDC23). | https://developer.apple.com/videos/play/wwdc2023/10248/, https://developer.apple.com/videos/play/wwdc2022/110350/, https://developer.apple.com/videos/play/wwdc2024/10173/, https://developer.apple.com/videos/play/wwdc2025/306/ | Free. |
| Swift, "Writing High-Performance Swift Code" | WMO, dynamic dispatch, large values, closure captures. Its stated audience is compiler and stdlib developers, so treat it as background. | https://github.com/swiftlang/swift/blob/main/docs/OptimizationTips.rst | Free. |

Note: the agent loop cannot drive the Instruments UI. Use `xctrace` from the command line and the `make bench` rule (decision 0022) for proof.

## 6. Distribution without notarization, Gatekeeper, codesign

| Pick | Use in this repo | URLs | Cost |
|---|---|---|---|
| Apple Support, "Safely open apps on your Mac" | The user-facing steps for the README: Privacy & Security, then Open Anyway, then confirm. | https://support.apple.com/en-us/102445 | Free. |
| Howard Oakley (Eclectic Light) | How Gatekeeper, quarantine, and ad-hoc signatures behave per macOS release. Free tools: Apparency (app signature view), Ulbow (log). | https://eclecticlight.co/2024/10/01/living-without-notarization/, https://eclecticlight.co/2024/08/10/gatekeeper-and-notarization-in-sequoia/ | Free. |
| Jeff Johnson | "Gatekeeper change in macOS 15.4": `CFBundleDocumentTypes` can cause Gatekeeper alerts. Dirigible declares a session document type, so this is a direct fit. | https://lapcatsoftware.com/articles/2025/4/8.html | Free. |
| Quinn "The Eskimo!" (Apple DTS) and technotes | The authority on code signing. Pinned "Code Signing Resources" forum post (login wall, not verified). TN3127 explains code signing requirements. | https://developer.apple.com/forums/thread/707080, https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements, https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac | Free. |

## 7. Testing Mac apps and Swift Testing

| Pick | Use in this repo | URLs | Cost |
|---|---|---|---|
| Swift Testing docs and repo | Primary API reference: traits, parameterized tests, `#expect`, parallel runs. Apache-2.0, ships with Swift 6 toolchains. | https://developer.apple.com/documentation/testing, https://github.com/swiftlang/swift-testing | Free. |
| WWDC24 Swift Testing sessions | "Meet Swift Testing" and "Go further with Swift Testing". | https://developer.apple.com/videos/play/wwdc2024/10179/, https://developer.apple.com/videos/play/wwdc2024/10195/ | Free. |
| Jon Reid (Quality Coding) | TDD on Apple platforms for 25 years. Fits the `tdd` skill. Recent: custom assertions in Swift Testing. | https://qualitycoding.org/ | Blog free. Book "iOS Unit Testing by Example" paid. |

Hudson and van der Lee publish Swift Testing agent skills (swift-mac.md).

## (a) Top 10 for this app, ranked

Rank rule: how often a reviewer would cite the source against real code paths here. Capture first, concurrency second, AppKit timeline third, distribution fourth, SwiftUI shell last.

1. Apple Core Audio taps docs. The capture path depends on them.
2. Ross Bencina, real-time audio 101. The audio-thread rules.
3. Swift Concurrency Migration Guide and Swift Evolution. Isolation of callbacks and actors.
4. AudioCap. A working tap and TCC reference.
5. Timur Doumler and Michael Tyson. Lock-free patterns that replace a lock.
6. Matt Massicotte. Practical isolation questions.
7. WWDC Instruments sessions and "Improving app responsiveness". Timeline and playback performance.
8. NetNewsWire and Brent Simmons. Real AppKit app code.
9. Howard Oakley, Jeff Johnson, and Apple Support 102445. The ad-hoc DMG path.
10. Michael Tsai. The aggregator for anything not above.

## (b) Seeds for review lenses or skills

Write our own rules in STE. Put a link after each rule. API facts and engineering rules are not copyrightable; the wording is. Do not paste paragraphs or slides.

1. **Real-time audio lens.** Sources: Bencina, Tyson, Doumler, Apple taps docs. Rules: list the banned calls in a callback (allocation, lock, log, file I/O, await, Objective-C messaging, Swift runtime calls that can allocate). Each rule gets a grep pattern or a test where possible. Keep "no locks" from AGENTS.md as the stricter rule.
2. **Concurrency lens.** Sources: the migration guide, SE-0466 and related proposals, Massicotte. Rules: where `nonisolated` and `@Sendable` must go, state change before the first `await`, and the main-actor inheritance trap in AGENTS.md. Each rule links one proposal or guide chapter.
3. **Distribution lens.** Sources: Oakley, Johnson, Apple Support 102445, TN3127. Rules: check the ad-hoc signature with `codesign --verify`, check `CFBundleDocumentTypes` for broad types, and keep the README first-open steps equal to the Apple Support page.
4. **AppKit craft lens for the UI panel.** Sources: HIG, NetNewsWire code, Tietze. Rules: menu and keyboard parity, standard responder chain use, document-window behavior. Use NetNewsWire's "passing tests do not prove a fix" line as a manual-check reminder.
5. **Performance skill.** Sources: "Improving app responsiveness" and WWDC23 10248. Steps: record a trace with `xctrace`, name the hang, then fix. Proof follows decision 0022.

## Not verified

- Tyson article body (HTTP 500). Rules come from a search snippet.
- Doumler talk page (HTTP 500). Video and slides URLs from search.
- Quinn forum post 707080 (login wall).
- Holly Borla forum profile (HTTP 403).
- Jalkut bitsplitting.org, Troughton-Smith GitHub, Liscio as SMUG blog author (search only).
- Migration guide page body (did not render).
- HIG "Designing for macOS" body (title only).
- Prices of Reichelt and Wals books.

## Sources

All URLs are inline above. Extra sources used:

- https://talk.objc.io/subscribe
- https://raw.githubusercontent.com/Ranchero-Software/NetNewsWire/main/CLAUDE.md (read)
- https://github.com/AudioKit/AudioKit
- https://developer.apple.com/documentation/coreaudio/catapdescription
- https://developer.apple.com/documentation/xcode/analyzing-responsiveness-issues-in-your-shipping-app
- https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
- https://developer.apple.com/videos/play/wwdc2023/10160/
- https://www.youtube.com/watch?v=zrWYJ6FdOFQ (search only)
- https://mjtsai.com/blog/2024/07/05/sequoia-removes-gatekeeper-contextual-menu-override/ (search only)
