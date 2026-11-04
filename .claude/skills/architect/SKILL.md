---
name: architect
description: "Sketch types, signatures, and module structure before code, then stay in the loop while implementation fills in. Use for /architect, 'architect this', 'design this', or non-trivial work where jumping to code would lock in the wrong shape."
---

# Architect

Sketch types, signatures, and module boundaries with `not implemented` bodies, synthesize one design from several candidates, then fill in code against it. Redesign when implementation proves the sketch wrong.

## Start

Open a todo list with one entry per phase: Ground, Sketch, Agree, Implement, Scrap.

## Phase A: Ground the problem

Spawn `Explore` subagents over each module that the new code touches, and trace the data flow from input to output. Produce the traced model: the types, the call path, and the owner of each piece of state. A file name is not a model. If the design redefines ownership or layering, also read the decision records in `docs/decisions/` and the `git log` of the touched files, so the rationale becomes a constraint, not a guess.

When the design depends on framework behavior that the documentation does not state (an error value, a format limit, a frame count), write a small probe with `swiftc -O`. Record the command, the macOS and Swift versions, and the result in `.scratchpads/runs/<run>/probe/output.txt`. Delete large generated files after the probe. Run the probe with `scripts/with-lock.sh scripts/probe.sh .scratchpads/runs/<run>/probe/<name> <binary>`.

A probe proves only the objects and the conditions it ran with. Probe the object that the design will query, in the production setup (a key window and the real responder chain, not a stand-in delegate). Mark each conclusion that goes past the printed result as an inference. When the design depends on an inference, the first slice that uses it starts with a test on the real object.

For each invariant over a shared resource (a volume, a device, the process), name its scope and every holder at that scope: other windows, other documents, sweeps, watchers. When one operation preempts another for the resource, the preempting operation runs every check that can refuse it before it ends the preempted work. It shows a refusal in the UI that has focus.

Skip Phase A only for greenfield work with no system around it.

## Phase B: Sketch

Spawn two or three `general-purpose` subagents in one message, one per candidate, with different models where possible (for example `opus` and `sonnet`). Give each the design task, the Phase A grounding, and `references/runner-prompt.md` as its prompt. Each candidate produces a design package shaped per `references/rationale-template.md`. Candidates work independently and do not see each other.

Design it twice: require at least two structurally distinct candidates (whole shapes, not point fixes in one shape), even when the first looks sufficient. This is the **exhaust-the-design-space** principle in `docs/principles.md`.

Screen every candidate against [`references/design-red-flags.md`](references/design-red-flags.md) before synthesis.

Compare viable candidates on interface depth: prefer the design that hides more complexity behind a smaller public surface.

Synthesize one design package, and write the choice in the "Synthesis decision" section of the rationale.

## Phase C: Agree (opt-in)

By default, implement the synthesized design with no human checkpoint. When the invoker asks for one ("/architect with checkpoint", "show me before implementing"), show the design and wait for sign-off.

The synthesis can ship as its own commit ("scaffold first", the **foundational-thinking** principle), and planned breakage during fill-in is fine (the **outcome-oriented-execution** principle), both in `docs/principles.md`. To attack the design before implementing, run the **interrogate** skill on the sketch (plan gate).

Treat human pushback on the shape as Phase A evidence: ground again and run Phase B again before more code.

## Phase D: Implement against the sketch

Replace `not implemented` bodies with code, pseudocode with logic. The synthesized sketch is the contract.

Report each deviation from the sketch. When a function needs a parameter that the sketch did not have, ask if the sketch was wrong, the requirement was missed, or the implementation does too much.

## Phase E: Scrap when the architecture is wrong

When implementation keeps fighting the sketch, throw the sketch out: do not bolt fixes onto a wrong design (the **redesign-from-first-principles** and **fix-root-causes** principles in `docs/principles.md`). The signal is a pattern:

- The same workaround again and again in unrelated code.
- Unrelated edge cases that each need a special-case branch.
- Types that need escape hatches (`any`, casts, optional fields always set in practice) to compile.
- The "we need a lock" reflex when the sketch said the state wasn't shared.
- Callers must know the internal rules of the abstraction.
- Two or more independent Phase D deviations of the same shape.

A few edge cases do not condemn an architecture: complexity in the data is not complexity in the design.

When you scrap:

1. Re-run the Phase A grounding over what's been built.
2. Redesign as if the new constraints had been day-one assumptions, per redesign-from-first-principles.
3. Subtract before adding, per the **subtract-before-you-add** principle in `docs/principles.md`. The new sketch should be smaller than the old one before it grows.
4. Return to Phase B and sketch again.

## Outputs

Write the caller's usage first and derive the type sketch from it: one file of types and signatures for a small change, a module map and type definitions for larger work. Save the rationale, shaped per `references/rationale-template.md` with the usage sketch and the synthesis decision, to `.scratchpads/runs/<run>/design.md`. Record a one-way decision (a file format, a module boundary, a threading model) in `docs/decisions/`.
