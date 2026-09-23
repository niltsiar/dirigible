# 0001. Native Swift app, built with SwiftPM only

- Status: accepted
- Date: 2026-09-23
- Amended: 2026-09-24. Capture uses one IOProc per device, not AUHAL (see 0004). The module names are in 0002.

## Context

The app must run on macOS 14 and later (R2), record several audio devices at the same time without an aggregate device (R3, R4), and process audio (R8, R9). The team has no Apple developer account (C1) and no CI server (C2). Agents do most of the work from a terminal, so every build and test step must run from the command line.

Compositor (https://github.com/robbietilton/Compositor), a native macOS image editor, is our reference for how to build a pro editor on macOS. We studied it on 2026-09-23. Its good parts: a value-type document with snapshot undo, a versioned package format with strict validation at load, per-concern IO actors, tests that drive the real session with fixtures generated in code. Its weak parts: layers are folders in one target, so the document code imports AppKit and IO types; one 900-line session object holds document, tool, and modal state; test helpers are copied into each file.

## Decision

- **Language and UI.** Swift 6 language mode with strict concurrency. SwiftUI for the app shell, menus, and inspectors. AppKit through `NSViewRepresentable` where SwiftUI is too slow or too limited, for example the waveform timeline.
- **Audio.** Apple frameworks first: Core Audio (AUHAL, one input unit per device), AVFoundation (`AVAudioFile`, `AVAudioEngine` for playback), AudioToolbox (`ExtAudioFile`, format conversion), Accelerate (vDSP for DSP). Add a third-party library only when the platform cannot do the job, and record that as a decision.
- **Build.** SwiftPM only. No Xcode project. `scripts/bundle.sh` makes `build/Dirigible.app` from the release binary and `Support/Info.plist`. The binary is universal (arm64 and x86_64), because the development Mac is Intel and most users have Apple silicon.
- **Modules.** Layers are SwiftPM targets, not folders, so the compiler enforces the dependency direction. The rules are in `AGENTS.md`. The first planning run names the modules.
- **Signing.** Ad-hoc signature (`codesign --sign -`). No hardened runtime and no App Sandbox, so the app can open any audio device and any folder the user picks.
- **Tests.** Swift Testing (`import Testing`), run with `swift test` through `make test`. Integration tests drive modules through their public API with real files and audio generated in code.
- **Format and lint.** `swift format` from the Xcode toolchain, configured in `.swift-format`. No other lint tool.

## Consequences

- No XCUITest. SwiftPM cannot host UI test bundles. Keep logic out of views so integration tests cover it. If UI automation becomes necessary, add an Xcode project generated from a spec (for example XcodeGen) that depends on the same package, and record that as a new decision.
- The microphone permission belongs to the code signature. An ad-hoc signature changes on every build, so macOS can ask for the permission again after a rebuild. A local self-signed certificate (`SIGN_IDENTITY`) keeps the permission stable. The README explains the setup.
- Users who download a build get a Gatekeeper warning, because the app is not notarized. The README explains how to open it.
- A cold universal release build takes about 35 seconds on the development Mac. Incremental builds take a few seconds.

## Alternatives considered

- **Xcode project (like Compositor).** Gives XCUITest, asset catalogs, and entitlements in the IDE. Rejected for now: the `project.pbxproj` file is hard for agents to edit and merge, and the build needs Xcode UI steps.
- **Cross-platform stack (Electron, Tauri, JUCE, Qt).** Rejected. The request is a Mac app (C3), and Core Audio gives direct, per-device capture with host-time stamps, which R3 and R4 need.
