# Research: SwiftFairy, its authors, and their network

Date: 2026-10-01

Method: WebSearch and WebFetch. WebFetch summarizes pages with a small model, so quotes below are from those summaries, not raw pages. "Unverified" means a search snippet only. I did not read any raw SKILL.md file.

## What SwiftFairy is

- A paid Mac app that runs a local MCP server. Coding agents send Swift and SwiftUI code to it. It parses the code into a graph, matches declarative patterns, and returns findings per line with explanation and fix examples (search summary of https://nilcoalescing.com/blog/IntroducingSwiftFairy/ and https://tools.nilcoalescing.com/swiftfairy).
- Site: https://tools.nilcoalescing.com/swiftfairy. Launch post: "Introducing SwiftFairy", 25 Sep 2026, author Matthaus Woolard (blog index).
- Knowledge is split into "Scrolls": Proper SwiftUI, Performant Swift Charts, Modern Swift. Modern Swift covers idiomatic APIs, concurrency API choices, collection processing (examples: `count(where:)` over `filter().count`, labeled breaks). It does not state AppKit or macOS coverage.
- Requirements: macOS 26.0 or later, Apple silicon. Version 2026.9.2. Free for one day, then lifetime, fixed-term, or subscription. Closed source.
- Claim in the post: agents "regularly miss rules stated in their AGENTS.md instructions and skills", so deterministic checks give a stronger signal than another skill (search summary; wording not verified on the raw page).
- Fit for this repo: out of scope as requested. Note only: it needs macOS 26 on Apple silicon, and the project memory says the dev machine is Intel on macOS 15. Closed and paid also conflicts with the third-party rule. Skip.

## Who made it

- Nil Coalescing, a New Zealand company (https://nilcoalescing.com). Authors: Natalia Panferova (ex SwiftUI team at Apple, book author) and Matthaus Woolard (@hishnash on GitHub and X).
- GitHub org https://github.com/nilcoalescing: SwiftUI-Code-Examples (304 stars, MIT), Swift-Code-Examples (MIT), Swift-Charts-examples, UnsafeCodable, plus djangochannelsrestframework (651 stars). No agent skills, AGENTS.md, rules, or MCP repo found there. SwiftFairy is their only agent product. The blog index shows no other AI-agent post.
- https://github.com/hishnash: indie Swift and Python developer, pinned KeyWindow (SwiftUI), member of the swift-numerics workgroup. No agent repos.
- Natalia's talks page (https://nilcoalescing.com/talks/): podcasts with Leo Dion (EmpowerApps, Mar 2025), Jeroen Leenarts (AppForce1), John Sundell (Swift by Sundell), Jason Dubon, Walid Sassi; talks at try! Swift Tokyo 2026 and iOS Conf SG 2026; swift.org blog post co-authored with Woolard (2022). None of these are about AI coding in the summaries.

Network conclusion: the authors do not publish skills or rules. The agent-skill ecosystem around them is the Hacking with Swift directory (https://github.com/twostraws/swift-agent-skills), which does not list Nil Coalescing. Most of its people are already covered in swift-mac.md (Hudson, van der Lee, Ricouard). New names from the directory and related searches are below. The follow and star graphs were not readable (hishnash follows 7 accounts; no list seen).

## Other skills found (not in the earlier file)

All fetched through WebFetch summaries.

1. **pchelnikov/Swift-6-Agent-Skill** (https://github.com/pchelnikov/Swift-6-Agent-Skill). MIT. Swift 6.0 to 6.4: concurrency defaults, Task.immediate, isolated deinit, typed throws, Mutex and atomics, noncopyable types, SwiftPM changes. Quote: "Every recommendation traces to a Swift Evolution proposal. No opinions, no folklore." Progressive disclosure, about 130 tokens metadata, about 20,000 tokens full. Quality looks high. Gap: no real-time audio rules (Mutex is not RT-safe), and it covers 6.3 and 6.4 where we pin 6.2.
2. **twostraws/SwiftAgents** (https://github.com/twostraws/SwiftAgents). One AGENTS.md, 1.4k stars, "targeting iOS 26 and later". No license shown in the summary. iOS biased.
3. **Xopoko/build-swift-apps** (https://github.com/Xopoko/build-swift-apps). MIT, 44 stars, 67 skill folders. Relevant names: macos-swiftpm-runner, macos-runtime-debugger, macos-test-diagnoser, macos-telemetry-probe, macos-appkit-bridge, macos-window-architect, macos-view-architect, swiftpm-build-inspector, swiftui-performance-inspector. Principle quoted: "Build, run, test, profile, or inspect before making broad claims". Bodies not read (raw paths returned 404). It points to RocketSim and `asc`, which are third-party. Many App Store skills are irrelevant.
4. **markmals/mac-dev-skills** (https://github.com/markmals/mac-dev-skills). MIT, 1 star, young. Claude Code plugin for macOS 26/27 AppKit: appkit-design, code-review, ui-testing, packaging, dev-workflow, appkit-app-inspector. Native tools moved to a separate `apple-platform-tools` repo. Needs Xcode 26 or 27. Quality unknown; the closest topical match to our AppKit timeline and on-screen checks.
5. **fayazara/macos-app-skills** (https://github.com/fayazara/macos-app-skills). MIT, 674 stars. Requires an Xcode project and Swift 5.9. Conflicts with our rules. Skip.
6. **jazzychad/ios-code-audit** (listed in the HWS directory, https://github.com/jazzychad/ios-code-audit). Code audit skill. Not read. iOS focus.
7. **Eduardo Bocato swift-testing-agent-skill** (https://github.com/bocato/swift-testing-agent-skill). Listed only. Not read. We already plan Hudson and van der Lee Swift Testing skills.

## Fit table

| Item | Covers | License | Quality | Fit |
|---|---|---|---|---|
| Swift-6-Agent-Skill | language and concurrency by SE number | MIT | high (claimed) | strict concurrency, SwiftPM; not RT audio |
| Xopoko macos-swiftpm-runner / runtime-debugger | run and inspect SPM macOS app | MIT | unknown | on-screen verification; we have scripts/hid.swift and screenshot.sh |
| mac-dev-skills | AppKit design, review, UI test | MIT | unknown, immature | timeline AppKit; Xcode 26 or 27 assumed |
| SwiftAgents | iOS 26 AGENTS.md | unclear | medium | low |
| SwiftFairy | paid MCP reviewer | closed | unknown | skip |

## Recommendations (at most 5)

1. **Add `.claude/skills/swift-6-reference/` adapted from pchelnikov Swift-6-Agent-Skill. Adapt.** Copy only the 6.0 to 6.2 references (concurrency, typed throws, Mutex, SwiftPM). Rewrite the description in STE and add a line that real-time audio callbacks never use Mutex or actors (AGENTS.md rule, decision 0013). Why: it ties advice to Swift Evolution proposals, so it catches stale agent habits cheaply. Risk: 6.3 and 6.4 advice breaks the Swift 6.2 ceiling, and the repo's THIRD_PARTY.md and decision record are needed for copied text. Check the license file first.
2. **Read `markmals/mac-dev-skills` code-review and ui-testing skills; borrow checklist items into the existing review agents. Adapt, do not install.** Why: AppKit-specific review items are missing from `.claude/agents/code-quality-reviewer`. Risk: young repo, unverified quality, plugin tooling needs Xcode 26 or 27 APIs. Read the raw files before copying anything.
3. **Read `Xopoko` macos-swiftpm-runner and macos-test-diagnoser; compare with `docs`/`verify-this` and `scripts/`. Adapt only a gap.** Why: same problem (SPM macOS app without Xcode project). Risk: probably duplicates our scripts; RocketSim dependency is third-party and needs a decision record. Likely outcome is skip if no gap.
4. **Skip SwiftFairy.** Paid, closed, needs macOS 26 on Apple silicon, an MCP dependency. Its idea (deterministic findings over prose rules) is valid: it supports putting Swift rules into lint or tests, which AGENTS.md already prefers ("Prefer a check over a new sentence"). No file change.
5. **Skip SwiftAgents and macos-app-skills.** iOS-only bias and an Xcode project requirement. Hudson's Swift Testing and Concurrency skills from the earlier file stay the first picks.

## Not verified

- Raw SKILL.md text for all items above. Licenses come from page summaries; the HWS directory says "Not specified" for most.
- Whether Nil Coalescing follow or credit any agent-skill authors. No such statement found.
- Matthaus's or Natalia's follow lists, and any AI-coding posts on X or Bluesky.

## Sources

- https://nilcoalescing.com/blog/IntroducingSwiftFairy/
- https://tools.nilcoalescing.com/swiftfairy
- https://tools.nilcoalescing.com/swiftfairy/modern-swift/
- https://nilcoalescing.com/blog/
- https://nilcoalescing.com/talks/
- https://github.com/nilcoalescing
- https://github.com/hishnash
- https://github.com/twostraws/swift-agent-skills
- https://github.com/twostraws/SwiftAgents
- https://github.com/pchelnikov/Swift-6-Agent-Skill
- https://github.com/Xopoko/build-swift-apps
- https://github.com/markmals/mac-dev-skills
- https://github.com/fayazara/macos-app-skills
- https://agentpedia.codes/agent-skills/mobile/macos-spm-app-packaging (origin: dimillian/skills, covered earlier)
