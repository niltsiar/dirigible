---
name: deslop
description: Remove AI-generated code slop from the current branch and clean up code style. Use for /deslop, "deslop this", or as the cleanup step before a review panel.
---

# Remove AI code slop

Check the diff of the current branch against `main` (`git diff main...HEAD` plus the working tree) and remove AI-generated slop that the branch introduced.

## Focus areas

- Extra comments that are unnecessary or inconsistent with local style. Keep comments that explain why, not what.
- Defensive checks, `do`/`catch` blocks, or `guard` statements that are abnormal for trusted code paths. Validation belongs at boundaries (file IO, device IO, user input).
- Force operations used only to silence the compiler: `!`, `as!`, `try!`, `@unchecked Sendable`, `nonisolated(unsafe)`, `Any` or `AnyObject` where a real type exists.
- Deeply nested code that early returns or `guard` make flat.
- Protocols with one conformer, wrappers that only forward calls, and configuration for values that never change.
- Dead code, unused parameters, and `TODO` notes without a ledger entry in `.scratchpads/`.
- Other patterns inconsistent with the file and surrounding codebase.

## Guardrails

- Keep behavior unchanged unless fixing a clear bug.
- Prefer minimal, focused edits over broad rewrites.
- Run `make check` after the edits. A deslop pass that breaks the build or the tests failed.
- Commit the result as its own `refactor:` or `style:` commit.
- Keep the final summary concise (1-3 sentences).
