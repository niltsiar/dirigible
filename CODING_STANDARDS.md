# Coding standards

A review applies these rules, the **Safety rules** of `AGENTS.md`, and the decisions that its **Read first** section names.

## Design

- **Simple first.** Choose the simplest design that meets the requirement. No protocol with one conformer, no factory for one product, no configuration for a value that never changes.
- **Apple frameworks first.** Core Audio, AVFoundation, AudioToolbox, Accelerate. A third-party dependency needs a decision record in `docs/decisions/`.
- **Modules are SwiftPM targets.** The compiler enforces the dependency direction: UI depends on domain, never the reverse. The domain module (session, tracks, clips, edits) imports only Foundation.
- **Thin app target.** The `DirigibleApp` executable target holds only the SwiftUI shell and wiring. Logic lives in library targets that integration tests can drive.
- **Validate at boundaries.** Parse files, audio devices, and user input into domain types at the boundary. Inside, trust the types.

## Concurrency

- **Isolation.** UI state is `@MainActor`. File I/O and DSP run off the main actor. Each capture device has its own writer.
- **Actors.** Each `await` lets another call run. Make the whole state change before the first `await`, or check the guard again after each `await`.

## Files

- **No warnings.** Fix a warning at its cause, never with a flag or an exception that hides it.
- **File size.** Split a Swift file over 400 lines by responsibility, not by execution order. A fix run adds an entry to `scripts/check-sizes.allow`; a refactor run splits.

## Tests

- Tests do not use the network, the real microphone, or a permission prompt.
