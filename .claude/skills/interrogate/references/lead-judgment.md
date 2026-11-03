# Lead judgment

You are the lead reviewer. Do not aggregate the findings: filter them, put them in context, and decide.

## Why the lead filters

Reviewers saw a slice of the code and the intent paragraph, so aggression makes noise. They do not know what the run tried and rejected, the constraints outside the code, the temporary scaffolding, or what the next pull request will do. Use your full context.

## Filters

- **Nitpick gravity.** With no critical issue, a reviewer inflates nits. When all findings of a reviewer are nits, the code is probably fine. Say so.
- **Hypothetical or actual.** A finding, a plan slice, or a fixer prompt needs a real caller that reaches the path. Fix a failure that only a test reaches in the test. Dismiss the finding when an upstream check or the type system prevents it: a reviewer that reads a diff cannot always see the call chain.
- **A failure of this run is actual.** Before you dismiss a finding as hypothetical, search the `decisions.tsv` of the run for the same failure. A failure that already happened in this run is actual.
- **Premature abstraction.** For a request to extract a function or to add an abstraction, ask: does this code need to change in a second way? If not, the abstraction is premature.
- **"I would have done it differently."** A finding that only prefers another approach is not actionable, unless it shows a concrete problem with the current approach. Dismiss it, and say why.
- **Missing context.** A finding on code that the author did not change, on a pattern that the rest of the codebase also uses, or against a constraint that you know, shows missing context. Dismiss it.

## When reviewers are right

Do not dismiss a finding because it is uncomfortable: the review exists to catch what you miss. A finding deserves attention when several models raise it independently, when its weight is `demonstrated` (`reviewer-prompt.md`), when it names a concrete execution path, when it shows a gap in your model of the code, or when you read it and think "...yeah, actually". Examine a security finding or a correctness bug more closely before you dismiss it, also when only one model raised it.

## Verdict calibration

A good verdict is useful, not complete: the user fixes the "Act on" items and ships with confidence. More than 5 "Act on" items of severity nit or warning usually means weak filtering. Show each dismissed finding and why, so the user can override your judgment.

## Invariant and Siblings

Each "Act on" item and taken nit, except a `no behavior change` nit, needs two fields (`scripts/check-plan.sh` checks them).

- **Invariant:** the broken invariant, named by the state, not the operation: "each use of the package path is the path the lock holds", not "each write goes to the locked path".
- **Siblings:** grep each folder that the rule text names (for example `Sources/` and `Tests/`), not only the module of the finding, for every read, write, and stored copy of that state, and each setter of it and of the trigger state. For a defect class (a tool failure read as success), list each instance. For a fix that adds or changes a user-visible rule, list each text that states it: the help and the tool description of each command that runs the changed path, the guide, and the agent manual. For an Invariant about a term or a value, run `rg` for each spelling of the bare term (a Range contains, a comparison pair, the old helper) over the changed files, and list each hit with its kept or changed meaning in the fix row. A copy that changes only at a write is a sibling. List each existing guard of the same invariant (an earlier check in a loop, a check before the close). With no sibling, write "none, grepped <what>". Prove each sibling that the fix leaves unchanged with a test, log, or control.

Pass the Invariant and Siblings fields to the fixer with the fix line. When a fix moves a value that a criterion pins (a count, a quoted phrase, or a state the user sees), name that criterion in the fix line. The fixer then edits the criterion in `analysis.md` and logs its `criterion change` row before the fix commit. At the first phase 7 row, `scripts/check-plan.sh` refuses a fix commit that removes a double-quoted text of a criterion with no `criterion change` row; it does not read a text in backticks. One commit fixes the finding and each sibling path. Accept a fix only when it covers each consumer the symptom names. When a fix relaxes or narrows a guard, drops a wait, moves a read across an `await`, or adds a state (a block rule, a marker file, an output line), name what the old code must still keep out or let through, and list each reader, start state, and exit under Siblings.

## Rounds

The workflow gives the reviewers the rule of each mode:

- Round 1, open: review the whole target.
- Each round after round 1, convergence: check only that each earlier "Act on" item is fixed correctly and consistently, and that no fix added a defect in what it changed. Report a critical defect anywhere. Nothing else.

In the convergence round:

- Only a finding about an earlier item or a fix can be "Act on". Exception: a critical finding (data loss, crash, security) can be "Act on" wherever it is.
- The workflow puts each non-critical finding whose `priorItem` is empty or "none" in `outOfScope`, without a skeptic. Add these with status later (`scripts/wiki.py add later --from <file>`) as "Consider" items with their lens. They do not block the gate.
- After you fix its "Act on" items, the gate is closed. Do not run another round. Keep each fix to the lines the finding names, so the fix does not open a new area.

## Fix check

After the fixes of the last round that runs (the convergence round, or round 1 of a 1-round gate), run one fix check: one `run-agent` agent with each "Act on" item of all rounds, its fix and lead ruling, and `analysis.md` (at the code gate, `git diff` of the fix commits of all rounds; at the plan gate, the diff against `plan-0.md` and `design-0.md`, which you copy before the first fix).

It answers four questions for each fix. Does the fix answer its finding? Does it add a rule or behavior that no finding asked for? What new failure does it add (the `new failure:` part below)? Does its text or its result on the `analysis.md` data contradict another fix, a settled gate item, or a criterion? For each fix that changes a criterion or its control, run that control on the changed tree, and write its exit status in the result. For a fix that changes a state that the user sees, check that a criterion names that state. The fix-check agent builds and drives no app. At the code gate, the lead also runs `scripts/verify-copy.sh ax dump` on a verify copy of the changed tree. The lead does so only when no push check runs (verify-this `references/driving-the-app.md`). A fix or a correction that picks an API option (a schedule mode, a parameter) cites a probe log, or states only the invariant.

Write the result under `## Fix check` in the last `review-<gate>-<n>.md` of the run folder. Give it one line for each "Act on" item of each round, starting `- <round>.<item>`, with `new failure: <the classifier, caller, or shared rule that the fix enters, for example a path that parallel callers share, or a file system call that exFAT refuses>` or `new failure: none: <reason>`. For a plan gate item that a `criterion change` row names as `(plan gate <r> item <i>)`, or that a `## Plan gate changes` item with a `Criteria:` ID names, the line also has `control: <logs/ or probes/ file> <result>`, where `<result>` is `exit <n>`, `<k> of <n>`, `PASS`, or `FAIL`, or `control: <logs/ or probes/ file> after <slice>`. `log-decision.sh` refuses the first phase 7 row until each item has its line, and each phase 4 row until each plan gate item has its line, for a run that starts after the cutoff in `scripts/check-plan.sh`. Correct a wrong fix. Add an added rule as an item with status later (`scripts/wiki.py add later --from <file>`). The fix check is not a review round, so it opens no new areas.
