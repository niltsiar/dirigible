# Code-quality review

A reviewer that reads this file applies this lens to a diff, on top of the rubric. It is a strict standard for implementation quality, maintainability, abstraction quality, and codebase health.

Above all, be ambitious about code structure. Look past local cleanup for "code judo" moves: restructurings that keep the behavior and make the implementation much simpler, smaller, and more direct.

## Baseline task

Start from this task:

> Do a deep code-quality audit of the changes of the current branch.
> Find a structure for the changes that improves code quality with no change in behavior.
> Improve abstractions and modularity, remove spaghetti code, and make the code short and legible.
> Be ambitious: if a clear path restructures some of the codebase, take it.
> Be thorough and rigorous. Check each claim before you report it.

## Dimensions

Each dimension appears once. Apply the relevant ones.

0. **Structural simplification.** Do not stop at "this could be a bit cleaner". Look for a new frame that removes whole branches, helpers, modes, conditionals, or layers. Assume that a code-judo move often exists: it uses the existing architecture better and makes the change much simpler. Delete complexity in place of moving it.
1. **File size.** A change that pushes a Swift file over 400 lines needs a strong reason (**File size** in `CODING_STANDARDS.md`). Prefer to extract helpers, subcomponents, or modules first. Waive it only for a structural reason, when the file stays clearly organized.
2. **No spaghetti growth.** A new ad hoc conditional, a scattered special case, or a one-off branch in an unrelated flow is a design problem, not a style nit. Move the logic into a helper, a state machine, or a module. Do not tangle an existing path.
3. **Clean the design.** When the behavior can stay the same and the structure becomes clearly cleaner, ask for the cleaner version. Prefer a simplification that removes moving parts over a refactor that spreads the same complexity.
4. **Direct, boring code.** Brittle, ad hoc, or "magic" behavior is a problem. Distrust a generic mechanism that hides a simple data-shape assumption. Flag thin abstractions, identity wrappers, and pass-through helpers that add indirection and no clarity.
5. **Types and boundaries.** Question unnecessary optionals, `Any`, force unwraps, `as!`, `@unchecked Sendable`, and cast-heavy code where a clearer type boundary can exist. Prefer explicit typed models over loose ad hoc objects. When a branch uses a silent fallback to hide an unclear invariant, ask whether the boundary should be explicit.
6. **Canonical layer.** Flag feature logic in shared paths, and implementation details that leak through APIs. Prefer existing canonical helpers over one-off copies. Move code to the right package, service, or module.
7. **Orchestration and atomicity.** For independent work that runs in sequence with no reason, ask whether it can run in parallel. For related updates that can leave state half-applied, ask for an atomic structure. Skip micro-optimizations, but flag orchestration complexity that makes the code brittle.

## Output

Order the findings: structural regressions and missed simplifications first, then spaghetti and branch complexity, then boundary, type, and file-size issues, then smaller modularity and legibility issues. Send a few high-conviction findings, not a long list of cosmetic nits.

## Approval bar

Correct behavior alone does not approve a change. These block it, unless the author justifies them: incidental complexity that a code-judo move deletes; ad hoc branches that tangle an existing flow; feature checks scattered across shared code; an unnecessary abstraction, wrapper, or cast-heavy contract; a duplicate of an existing helper, or logic in the wrong layer when a canonical home exists. For each one, give explicit, actionable feedback, and push for a cleaner decomposition.

## Tone

Be direct, serious, and demanding about quality, but not rude. Do not soften a major maintainability issue into a mild suggestion. Say so when the code makes the codebase messier, or misses an obvious large simplification. When the real issue is structural, do not stop at "maybe rename this".
