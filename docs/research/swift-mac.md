# Research: published agent skills and rules for Swift and macOS

Date: 2026-10-01

Scope: skills and rule sets that could help the Dirigible loop (Swift 6.2, Swift Testing, SwiftUI and AppKit, Core Audio, SwiftPM with no Xcode project, zero warnings). I read each page with WebFetch, which summarizes the page. I did not read raw SKILL.md files except where marked "read". Anything marked "unverified" came only from a search snippet.

Repo today: skills are process skills only (deliver, tdd, architect, interrogate, deslop, verify-this, and so on) in `.claude/skills/`. No Swift-API skill exists. The Swift rules live in CODING_STANDARDS.md and in AGENTS.md "Safety rules" and "Testing rules".

## The user's two references

**Guilherme Rambo (insidegui).**
- Found: one repo, `insidegui/srdskills`, described as "Coding agent skills for working with Apple Security Research Device" (https://github.com/insidegui?tab=repositories&q=agent). It is for SRD hardware, not app work.
- Not found: any AGENTS.md, CLAUDE.md, cursor rules, or a post on AI coding for Swift. The twostraws directory also lists none by him. One search for his AI opinions returned nothing from him.
- Fit: none for this repo. The skill format of `srdskills` is a possible style reference only (unverified, not read).

**Daniel Steinberg (Dim Sum Thinking).**
- Found: a search snippet says he wrote an essay on agent-assisted coding and on whether refactoring still matters when AI keeps the code. The snippet points at LinkedIn, not at a primary page (unverified). No skills, rule files, or prompt files found.
- Fit: none for tooling. He is useful for ideas on refactoring, not as a source of files.

## Community sources

### 1. Paul Hudson (Hacking with Swift): SwiftUI Pro, Swift Concurrency Pro, Swift Testing Pro, SwiftData Pro
- Where: https://github.com/twostraws/SwiftUI-Agent-Skill, https://github.com/twostraws/Swift-Testing-Agent-Skill, directory https://github.com/twostraws/swift-agent-skills, article https://www.hackingwithswift.com/articles/282/swiftui-agent-skill-claude-codex-ai
- Covers: "targets the mistakes LLMs actually make", for example "buttons invisible to VoiceOver" and deprecated API. Topics: navigation, layout, animation, state, accessibility, performance. Swift Testing Pro covers `@Test`, `#expect`, `#require`, parameterized tests, traits, exit tests, confirmations.
- Platform: README says "Designed for iOS 26 and later" and "Swift 6.2 and later". MIT license. Install: `npx skills add ... --skill swiftui-pro`.
- Quality: high, popular (the search result says it became the most starred Swift skill within a week). Written as short rule lists, token efficient per its contribution guide.
- Fit: Swift Testing and Swift Concurrency are a direct match for TDD and strict concurrency. SwiftUI Pro is iOS-biased (NavigationStack, iOS 26 APIs). Our target is macOS 14 and later and the timeline is AppKit.
- I did not read the individual reference files.

### 2. Antoine van der Lee (SwiftLee): Swift Concurrency, Swift Testing, SwiftUI, Core Data skills
- Where: https://github.com/AvdLee/Swift-Concurrency-Agent-Skill, article https://www.avanderlee.com/ai-development/swift-testing-agent-skill-write-high-quality-tests-with-ai/, https://www.avanderlee.com/ai-development/agent-skills-replacing-agents-md-with-reusable-ai-knowledge/
- Covers (concurrency): safety and isolation, `Sendable`, actors, performance, "Swift 6 Migration", testing, and Swift 6.2 items: "default actor isolation", "isolated deinit", "Approachable Concurrency build settings". Layout: `SKILL.md` with decision trees plus `references/*.md` (actors, sendable, migration, testing, and 10+ more). MIT. Ships as a plugin with manifests for Claude Code, Cursor, Codex.
- Quality: high. It states its basis as "industry-standard best practices and compile-time safety, not architectural preferences". Progressive disclosure matches our context budget rules.
- Fit: best match for the concurrency lens. Gap: it says nothing on real-time audio threads or Core Audio C callbacks (not seen in the summary; unverified). Our decision 0013 already covers that.
- Caution: it advises Approachable Concurrency and default MainActor settings. Our rules and Package.swift may set different isolation. Check before adoption.

### 3. Thomas Ricouard (Dimillian): Skills repo (16 skills, MIT)
- Where: https://github.com/Dimillian/Skills
- Skills seen in the listing: swiftui-ui-patterns, swiftui-view-refactor, swiftui-performance-audit, swift-concurrency-expert, macos-spm-app-packaging, macos-menubar-tuist-app, ios-debugger-agent, review-swarm, bug-hunt-swarm, review-and-simplify-changes, orchestrate-batch-refactor, project-skill-audit.
- Read: `swiftui-performance-audit` is "code-first, then profiling" with six steps (classify, review code, ask for Instruments traces only if needed, analyze, remediate, verify with before/after). It states no platform limit. It names "invalidation storms from broad observation or environment reads" and "unstable identity in lists" as the main causes.
- Read: `macos-spm-app-packaging` covers SwiftPM macOS apps "without Xcode": `package_app.sh`, `compile_and_run.sh`, `sign-and-notarize.sh`, Sparkle appcast, `codesign -dv --verbose=4` checks, a hardened-runtime note. Close to our `make app`, `make run`, `make dmg`.
- Read: `review-swarm` runs four read-only lenses (regression, security and privacy, performance and reliability, contracts and coverage), then filters hard: it "drops duplicates, weak or speculative claims ... minor style comments".
- Quality: medium to high, opinionated. He says so himself on X: "very opinionated" (https://x.com/Dimillian/status/2007866774273032637, from a search snippet).
- Fit: the performance audit and the packaging checks transfer. The review swarm overlaps our own `interrogate` panel, which already has more lenses. Skip those. The IceCubes agent rules were not checked (unverified).

### 4. Point-Free: "The Point-Free Way"
- Where: https://www.pointfree.co/the-way
- Covers four skills: Composable Architecture, Dependencies, Swift Navigation, SQLiteData. Installed with `brew install pointfreeco/tap/pfw`. Needs a paid membership. The page gave no license for the skills.
- Fit: poor. The skills assume their libraries. CODING_STANDARDS.md requires a decision record for a third-party dependency, and "Simple first" rules out TCA. Skip. The idea "testable by design" is already in our TDD rules.

### 5. Apple: Xcode 26.3 agentic coding
- Where: https://9to5mac.com/2026/02/26/apple-releases-xcode-26-3-with-support-for-agentic-coding/ (secondary press, not an Apple page).
- Covers: Claude Agent and Codex inside Xcode, and an MCP server exposing about 20 Xcode tools (build, tests, previews, docs search).
- Fit: none. We have no Xcode project, and the Intel Mac runs Xcode 26.3 as the newest usable (memory note). The MCP route adds a dependency without a gain. Apple's docs-search idea is useful but needs Xcode. Skip. I did not find an Apple page of AI-assistant guidance for Swift (unverified).

### 6. AppKit, Core Audio, real-time audio
- Search found no published agent skill for AppKit or Core Audio. The twostraws directory also says it lists none ("No AppKit, macOS-specific, Core Audio ... skills"). Only blog posts and forum threads exist (for example the Apple forum thread on AVAudioEngine thread safety). Our AGENTS.md concurrency rule and decision 0013 are likely the best text that exists. This is a gap to fill ourselves, not to import.

## Conflicts with repo rules
- iOS bias: SwiftUI Pro and Dimillian UI skills assume iOS 26 and Liquid Glass. We target macOS 14 and later on an Intel Mac with Xcode 26.3. Strip iOS-only lines.
- Dependencies: Point-Free needs libraries. Dimillian packaging adds Sparkle and Tuist, and we have no notarization (memory: no Apple developer account).
- Zero warnings and Swift 6.2: Approachable Concurrency and default MainActor settings change compile behavior. Check against Package.swift before copying advice.
- STE100 rule: all third-party skill text is not STE. Copied files need a rewrite to pass our writing rules, and "Keep this file true" limits budget. Licenses are MIT, so copying is legal if we keep the notice (`.claude/skills/THIRD_PARTY.md` already exists for this).
- Install route: `npx skills add` fetches code from the network. Copy a pinned commit instead.

## Recommendations (at most 6)

1. **`.claude/skills/swift-concurrency/` from AvdLee. Adapt.** Copy only SKILL.md and the references for actors, Sendable, testing. Add a short section from AGENTS.md: real-time callbacks `nonisolated` and `@Sendable`, no locks or allocation, decision 0013. Why: the loop's worst bugs (main-actor inheritance, `await` re-entrancy) are in this area. Risk: advice may clash with our isolation settings. Read Package.swift first. Pin the commit and add a THIRD_PARTY row.

2. **`.claude/skills/swift-testing/` from Hudson or AvdLee. Adapt.** Pick one, not both. Cut XCTest and UI-test parts. Link it from `tdd`. Why: agents write XCTest by habit. Our AGENTS.md says "Swift Testing" only through the brief. Risk: size. Keep SKILL.md under about 150 lines and the rest in references.

3. **Hudson SwiftUI Pro, reduced. Adapt.** Keep the deprecated-API and accessibility rules for macOS. Drop iOS navigation and Liquid Glass. Why: it targets real LLM mistakes. Risk: wrong for the AppKit timeline. Mark it "SwiftUI shell only".

4. **Dimillian `swiftui-performance-audit` as a perf lens. Adapt.** Add the code-first, then Instruments, then before/after flow to the review lens or `verify-this`. Why: it matches our "prove a claim" flow and our 0022 bench rule. Risk: low. Keep it a short checklist.

5. **Dimillian `macos-spm-app-packaging`: skip as a skill, mine for checks.** Add `codesign -dv --verbose=4` and `ls -R` bundle checks to the packaging verification only if `make test-app` lacks them. Why: our Makefile already covers build, run, and DMG. Risk: none if skipped.

6. **Write our own `macos-appkit-coreaudio` skill later. New, not an import.** Nothing published fits. Source it from our decisions (0013) and past run learnings. Why: it is the real gap. Risk: more context load. Put it behind a path-scoped trigger. Do this only after one more bug of this kind (seen-once rule in `reflect`).

Skip: Point-Free, Xcode MCP, Dimillian review and bug swarms (duplicate `interrogate`), anything by Rambo or Steinberg (nothing exists).

## Sources
- https://github.com/twostraws/swift-agent-skills (directory, read by summary)
- https://github.com/twostraws/SwiftUI-Agent-Skill (read by summary)
- https://github.com/twostraws/Swift-Testing-Agent-Skill (search snippet only)
- https://www.hackingwithswift.com/articles/282/swiftui-agent-skill-claude-codex-ai (snippet only)
- https://github.com/AvdLee/Swift-Concurrency-Agent-Skill (read by summary)
- https://www.avanderlee.com/ai-development/swift-testing-agent-skill-write-high-quality-tests-with-ai/ (snippet only)
- https://github.com/Dimillian/Skills and raw SKILL.md files of swiftui-performance-audit, macos-spm-app-packaging, review-swarm (read by summary)
- https://x.com/Dimillian/status/2007866774273032637 (snippet only)
- https://www.pointfree.co/the-way (read by summary)
- https://github.com/insidegui?tab=repositories&q=agent (read by summary)
- https://www.dimsumthinking.com/Info/ and LinkedIn snippet for Steinberg (unverified)
- https://9to5mac.com/2026/02/26/apple-releases-xcode-26-3-with-support-for-agentic-coding/ (snippet only)
