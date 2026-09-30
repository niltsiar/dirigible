# Performance criteria and loop rules

## A performance criterion

- A performance criterion names its build configuration (debug or optimized) and its size, for example the window size in pixels. Its test asserts the real budget under those conditions.
- Name the make target that runs the test, for example `make bench FILTER=<test>` for an optimized budget.
- A timing at other conditions is a proxy and cannot close the criterion. A criterion that no committed command runs is a manual check.
- The criterion names each input path that reaches the costly code (each gesture that redraws), the worst-case fixtures (many items per lane, one item wider than the view, a change at the end), and the real input rate. A path that the criterion does not name is not covered by its budget.
- A pointer gives at most one event per display frame, so the benchmark sends one event per frame: events sent back to back measure the frame throttle.
- A budget cannot see a regression that stays under it. For a known slow cause (a view body that runs again), also assert a count that does not use time, with a control that puts the cause back.
- A test that reads a DEBUG-only counter is in `#if DEBUG` too: `make bench` builds the tests with no DEBUG.
- In a bench that times two events in one frame (a real event, then a tick), assert for each event that it changed the output, as a Bool after the clock stops. Run a control that sends the same input twice: a per-frame count passes when either event does the work.

## A new way to move or resize something

- When a change adds a new way to move or resize something (a drag, an inset, a zoom), list each redraw or cache guard that reads that geometry. Give each one a test where the new input changes the drawn output while the key of the guard stays the same.
- These fixtures and the on-screen checks include the default state: fit zoom, origin 0, a document shorter than the view. A scrolled fixture can hide a stale drawing, because AppKit copies the pixels at a scroll.

## A rule that classifies loop runs

- A rule that classifies a loop run or names the holder of a sample (a trigger that picks a plan branch) is a script in the run folder, not prose.
- Write it before the data, and run it on the green runs of the baseline loop before the plan gate. A rule that fires on green runs decides nothing: "the failed run has samples that name a CLI test" fired on every run, because each sample named a CLI test.
- A rule that changes after the data is a criterion change (Phase 4 step 4).
