# Review rubric

Apply only the relevant sections.

## Correctness

Does the code do what the intent says?

- Edge cases: empty input, nil, boundary values, concurrent access.
- Error handling: is each error caught, propagated, or silently dropped?
- Off-by-one errors, type coercion, integer overflow, string encoding.
- State: race conditions, stale closures, dangling references.
- Do the happy path and the sad path work?
- Idempotency: what happens when the operation runs twice, or after an earlier run crashed halfway? "It depends on the state that was left" means a missing reconciliation step.
- Concurrency: when several actors change the same mutable state (files, branches, shared data), does the structure serialize the access (locks, sequential phases, exclusive ownership), or only a convention that will not hold?

For a possible bug, trace the execution path: show the call chain that makes the value nil, not only "this could be nil".

## Root cause or symptom

Does the code fix the actual problem, or hide a symptom? Read beyond the changed files: the callers, the callees, the type definitions, and the sibling modules (Read, Grep, Glob). Understand why the code exists before you judge whether the change is in the right layer.

- A guard clause that hides a deeper invariant violation.
- Retry logic that hides a broken contract.
- A type cast that hides a modeling error.
- A workaround: why is it necessary, and what would a correct fix look like?
- A fix in module A that belongs in the contract of module B.
- An instruction where structure is better: for a "don't do X" comment or a convention that someone must remember, ask if a type constraint, a lint rule, or a runtime check can make the wrong thing impossible.

## Structural integrity

Does the code fit the system?

- Boundaries: validate data once where it enters the system, then trust it inside. Validation scattered through business logic is a finding.
- Abstraction level: does the code mix high-level orchestration with low-level detail?
- Coupling: does the change add a dependency that makes future changes harder?
- Data model: do the data structures match the access patterns? The right structure makes the downstream code obvious. The wrong one fights each change.
- Bolted on or integrated: if the requirement had been known from the start, would the code look like this?
- Legacy dual paths: a new API next to an old one that stays alive. With no external consumer, migrate the callers and delete the old path in the same change. A compatibility layer that stays becomes permanent.

Do not penalize simple code for a lack of abstraction. Premature abstraction is worse than duplication: three lines of duplication beat a premature abstraction.

## Verification

Can you tell from the code that it works?

- Do tests exist, and do they test behavior, not implementation details?
- Do assertions or invariants catch a regression?
- A bug fix has a test for the bug. A change at an integration boundary tests the full path.
- Check the real thing, not a proxy: liveness from a file mtime or a cached state, in place of the actual value, is a verification gap.
- Delegated or async work: does the code check the actual output artifacts, or trust self-reports and summaries?

## Complexity budget

Does the result justify the complexity?

- Code that can be simpler and stay correct and clear.
- An abstraction with one call site.
- Configuration or parameters for cases that do not exist yet.
- Dead code, unused imports, vestigial parameters.
- "Just in case" code paths with no current caller.
- A compatibility path for a migration that is done: delete the scaffolding.
- Does the user experience justify the complexity? Each feature, control, and option earns its place. A half-finished feature is worse than a missing one.

Simpler is better, unless simpler is wrong.

## Audio and real-time safety

Only for code that touches audio I/O or DSP.

- No allocation, lock, file I/O, logging, or Swift `async` work on a real-time audio thread (render or input callbacks). Hand data to another thread through a lock-free ring buffer, or through `AVAudioFile` on a writer queue.
- Each capture device has its own clock. Look for code that assumes that two devices share a sample clock or a start time. A recording stores the timing data (host time, sample time) to align the tracks later.
- A recording survives a crash or a device disconnect: the audio already captured stays on disk and readable.
- Sample-rate and channel-count conversions are explicit. No silent resampling.
- Compare DSP output with a tolerance, not with exact equality.

## Security

Flag only a security issue that you can trace through the code. "This could be an injection vector" without the input path is not useful.

- User input that reaches a dangerous sink (SQL, shell, eval, innerHTML) without sanitization.
- Authentication or authorization gaps in new endpoints.
- Secrets in code, logs, or error messages.
- Time-of-check to time-of-use (TOCTOU) races in security-critical paths.
