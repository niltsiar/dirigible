# Engineering principles

Skills and reviewers cite these principles by name. Each rule is one line. When two rules conflict, the simpler solution wins unless it loses data or breaks a test.

Source: the principle skills of pstack (https://github.com/cursor/plugins, `pstack/skills/principle-*`, MIT, Copyright (c) 2026 Lauren Tan). We shortened them and added the audio notes.

## Core

- **laziness-protocol.** Prefer deletion and the smallest change that solves the problem.
- **foundational-thinking.** Choose the core types and data structures before you write logic. The right data structure makes the downstream code obvious.
- **redesign-from-first-principles.** When a requirement changes, redesign as if it was a day-one assumption. Do not bolt it on.
- **attack-the-premise.** When two fixes with the same premise fail the same gate, question the premise before you write a third fix.
- **subtract-before-you-add.** Remove dead code, redundant checks, and stubs first. Then build on the simpler base.
- **minimize-reader-load.** Count the layers between a question and its answer. Remove one-caller wrappers. Keep mutable state in the smallest scope.
- **outcome-oriented-execution.** In a planned migration, go to the target design. Do not keep temporary compatibility code alive.
- **experience-first.** Choose what the podcast producer feels over what is easy to implement. Ship fewer features that work well.
- **exhaust-the-design-space.** For a one-way decision, sketch two or three different designs and compare them before you commit to one.
- **build-the-lever.** When work repeats, write the script, test, or generator that does it or proves it. A reviewer can run the script again.

## Architecture

- **model-the-domain.** Put domain rules in types and data (a session, a track, a clip), not in conditionals spread across the code.
- **boundary-discipline.** Validate at the boundaries: files, audio devices, user input. Inside the system, trust the types. Keep business logic in pure functions.
- **type-system-discipline.** Make illegal states impossible to represent. Parse external data into domain types at the boundary. Do not lie to the compiler with force casts. Handle every enum case.
- **make-operations-idempotent.** An operation that runs twice, or crashes halfway and runs again, gets to the same end state.
- **migrate-callers-then-delete-legacy-apis.** Move every caller to the new API and delete the old API in the same change.
- **separate-before-serializing-shared-state.** Before you add a lock, remove the sharing. Give each actor its own state and merge at the read boundary. Audio note: each capture device writes its own file on its own queue.

## Verification

- **prove-it-works.** Check the real artifact: run the app, read the file, measure the level. "It compiles" is not proof.
- **fix-root-causes.** Reproduce first. Ask why until you find the cause. Fix it there. Do not add a guard that hides a crash.
- **sequence-verifiable-units.** Split work into small units. Each unit ends in a state you can check. Do not start the next unit until the check is green.
- **test-behavior-not-implementation.** Call the code as its users do and assert a literal expected result. The **tdd** skill says when a test proves nothing.

## Delegation

- **guard-the-context-window.** Send bulk reading to subagents. Keep summaries in the main thread, not raw output.
- **never-block-on-the-human.** Proceed on reversible work, show the result, and let the human correct it later. Ask first only for irreversible actions.

## Meta

- **encode-lessons-in-structure.** When you write the same instruction twice, change it into a lint rule, a test, a script, or a type. A mechanism beats a sentence.
