# Architect runner prompt

The orchestrator passes this file through to every parallel candidate runner during Phase B and fills in the variable inputs around it: the task, the Phase A grounding artifacts, the isolated working directory, and the path to write outputs. The working directory is a git worktree when available, otherwise a per-runner subdirectory under the sketch dir. What matters is independence between candidates.

You are producing one candidate design in architect's parallel exploration. Read the **architect** skill in full first. That's the workflow you're inside. Output a candidate design package: type sketch, function signatures, module map, and prose rationale shaped per [`rationale-template.md`](rationale-template.md).

Apply the following discipline. The orchestrator compares candidates on these axes to pick a base.

- Caller's usage first. Write the README-style usage and two or three real call sites before the types, then derive the type sketch from them. The usage is the spec. The two must agree, so reconcile the sketch to the usage, not the reverse.
- State machines as a table. When a type has a lifecycle (a take, a document, a connection), write a table of states x events. Every cell names the next state, or the error it throws. Include the failure events: crash, a thrown step, a reopen. A missing cell is a missing design decision.
- Persisted-format refusals as a table. When the design reads a file format, list each value the reader refuses. For each row, name the type or edit that makes the value impossible to produce. A refusal with no enforcing type lets an edit save a file that the reader cannot open. Each row gets an edit, save, and read test.
- Framework faults as a table. When the design treats two faults differently (a fault that can go away and a fault that cannot), list each fault. For each row, name the value that the real API returns and the probe that showed it. Also probe a look-alike case with no fault. Core Audio, AudioToolbox, and AVFoundation return an `OSStatus`, not an `errno`, and one status can mean two faults. A row with no probe is a guess.
- Callback-reachable memory as a table. When an OS callback gets a raw pointer (client data, a context, an `Unmanaged` reference), list each allocation it can reach. For each row, name the callbacks that reach it, the place that frees it, and the barrier that proves no call still runs there, with the probe that shows the barrier. Find siblings by free site, not by code path: every free of that memory is a row. If no probe proves a barrier, keep the memory for the process life. Then state the growth per take in the long-lived app, not only in the CLI.
- Data structures first. Get the core types right and the code becomes obvious. Trace each dominant access pattern through the proposed structure. If the answer is "we'll add a map / index / cache later," the structure is wrong.
- Interface depth. Compare the capability hidden behind the public surface relative to the size of that surface. Prefer a simple interface that pulls complexity into the callee, even when the implementation becomes less simple. Do not put transport or wire types on the public API. Parse into domain types behind the interface.
- Shared state: if two actors might both write, ask "what happens?" If the answer isn't "nothing," default to per-actor state with a merge at the read boundary, per the **separate-before-serializing-shared-state** principle in `docs/principles.md`.
- Make boundaries visible. `not implemented` errors for bodies, `// TODO` pseudocode for tricky logic, doc comments stating intent and invariants. A reader should trace data from input to output by reading types and signatures alone.
- Encode invariants in types: hard-to-misuse types > runtime checks > prose comments, per the **encode-lessons-in-structure** principle in `docs/principles.md`.
- Validate at boundaries, trust types inside, per the **boundary-discipline** principle in `docs/principles.md`. Business logic as pure functions. The shell stays thin.
- Single source of truth per invariant. Derive instead of sync.
- Idempotent state transitions where applicable, per the **make-operations-idempotent** principle in `docs/principles.md`. Ask what happens if the operation runs twice or crashes halfway.
- Short call chains. If tracing the flow needs more than three files, flatten the hierarchy, per the **laziness-protocol** and **minimize-reader-load** principles in `docs/principles.md`.

You are one of several runners, each on a different model. Produce the best design your model can make. Don't hedge against the others. Differences between candidates are the signal used to pick a base and graft. Converging on a safe-looking middle defeats the exploration.
