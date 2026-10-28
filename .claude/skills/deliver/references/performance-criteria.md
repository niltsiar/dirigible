# Performance criteria and loop rules

## A performance criterion

- A performance criterion names its build configuration (debug or optimized), its size (for example the window size in pixels), and its make target (`make bench FILTER='<name> <name>'`). Its test asserts the real budget under those conditions.
- A timing at other conditions is a proxy: it cannot close the criterion, and a debug miss only prints (`expectWithinBudget`). A criterion that no committed command runs is a manual check.
- The criterion names each input path that reaches the costly code (each gesture that redraws), the worst-case fixtures (many items per lane, one item wider than the view, a change at the end), and the real input rate. A path that it does not name is outside its budget.
- The benchmark sends one event per display frame, as a pointer does: events back to back measure the frame throttle.
- A budget misses a regression under it. For a known slow cause (a view body that runs again), also assert a time-free count, with a control that puts the cause back.
- A test that reads a DEBUG-only counter is in `#if DEBUG` too: `make bench` builds the tests with no DEBUG.
- In a bench that times two events in one frame (a real event, then a tick), assert for each event that it changed the output, as a Bool after the clock stops. Run a control that sends the same input twice: a per-frame count passes when either event does the work.

## A time budget

- In Phase 1, give each relative budget a time limit that a user feels (50 ms, 3 frames at 60 Hz): it is the absolute part of a relative budget, in each phase. Before a run judges a path that main also runs by that limit, measure main on the same path first, in alternated main and branch runs on one machine (`scripts/bench-pairs.sh` runs them). A miss that main shares is a next item, not a NOT VERIFIED of the run. Each budget clears the A/A spread of that bench.
- Before the plan gate and each fix try, sum the measured parts of the path, name the limiter, and compute the best possible saving. A bound that cannot meet the budget makes the design change a planned slice, or a `criterion change`.
- Before the first try of a bench miss, run `scripts/bench.sh --trace <run>/logs/<name>.trace --under <wrapper> <name>`, with `<wrapper>` the `@inline(never)` function of the timed span (add one if missing, as `NavigationKeyBenchmark.timedSpan`). The try row names the top frames.
- A try is one change, `make bench` before and after, and the slice tests. Keep a gain past the A/A spread, else revert in full. One `decisions.tsv` row per try; no pairs.

## A new way to move or resize something

- For a new way to move or resize something (a drag, an inset, a zoom), list each redraw or cache guard that reads that geometry. Give each a test where the new input changes the drawing and the guard key stays the same.
- These fixtures and the on-screen checks include the default state (a fit zoom whose frames per point is not a whole number, origin 0, a document shorter than the view) and the state after a commit (a second gesture). A scrolled fixture can hide a stale drawing, because AppKit copies the pixels at a scroll.

## A rule that classifies loop runs

- A rule that classifies a loop run or names the holder of a sample (a trigger that picks a plan branch) is a script in the run folder, not prose.
- Write it before the data, and run it on the green runs of the baseline loop before the plan gate. A rule that fires on green runs decides nothing.
- A rule that changes after the data is a criterion change (deliver Autonomy rules).
