# Coding standards

A review applies these rules and the decisions that the **Read first** section of `AGENTS.md` names.

## Safety

- **No data loss.** Captured audio stays on disk and readable after a crash, a device unplug, or a full disk. Session saves are atomic. A WAV header gets its data size only when the file closes, so write captured audio in a format that survives a crash (for example CAF) or repair the header at launch.
- **Real-time thread.** Nothing on a real-time audio thread allocates, locks, logs, does file I/O, or awaits.

## Design

- **Simple first.** Choose the simplest design that meets the requirement. No protocol with one conformer, no factory for one product, no configuration for a value that never changes.
- **Apple frameworks first.** Core Audio, AVFoundation, AudioToolbox, Accelerate. A third-party dependency needs a decision record in `docs/decisions/`.
- **Open-source code.** Port soundcraft code (MIT or Apache-2.0) only with its license notice, in the same commit: in the ported file and in `Support/Resources/`, as for LAME. Read Audacity code (GPLv3) for the approach only: never copy, port, or translate it. Never decompile or disassemble a closed app, and never copy its code or its assets. Read only its public documentation, its behavior in use, and text in the installed app, such as menu and command names.
- **Modules are SwiftPM targets.** The compiler enforces the dependency direction: UI depends on domain, never the reverse. The domain module (session, tracks, clips, edits) imports only Foundation.
- **Thin app target.** The `DirigibleApp` executable target holds only the SwiftUI shell and wiring. Logic lives in library targets that integration tests can drive.
- **Validate at boundaries.** Parse files, audio devices, and user input into domain types at the boundary. Inside, trust the types: read an enum payload with a switch or one named function for each meaning, because a `?? <empty value>` merges its cases again.

## Concurrency

- **Isolation.** UI state is `@MainActor`. File I/O and DSP run off the main actor. Each capture device has its own writer.
- **Actors.** Each `await` lets another call run. Make the whole state change before the first `await`, or check the guard again after each `await`. The test of a recheck queues a competing actor call first, so that call runs inside the `await`.
- **Skill.** `.claude/skills/swift-concurrency/SKILL.md` has the Swift Concurrency patterns. The rules here win over it.

## Files

- **No warnings.** Fix a warning at its cause, never with a flag or an exception that hides it.
- **File size.** A Swift file under `Sources/` or `Tests/` over 400 lines needs a reason in `scripts/check-sizes.allow`. A fix run adds the entry. A refactor run splits the file by responsibility, not by execution order.

## Tests

- Apply the **Guardrails** of `.claude/skills/tdd/SKILL.md`.
