---
name: verify-this
description: "Use for \"verify this\", \"prove it works\", \"did this fix it\", or before a run marks a task done. Verify a claim with fresh local evidence: restate it falsifiably, capture baseline and treatment, compare artifacts, and return VERIFIED, NOT VERIFIED, or INCONCLUSIVE."
---

# Verify This

Verification is not a recap. It proves or disproves a specific claim with repeatable evidence.

## When To Use

- The user asks "verify this", "prove it works", "did this fix it", or "show me the evidence".
- A bug fix needs a before/after repro.
- A UI, CLI, API, performance, or memory claim needs measurement.
- A test passes but the user-visible behavior still needs confirmation.

Do not use this for vague claims like "the code is cleaner". Ask for a measurable claim first.

## Workflow

1. Restate the claim in falsifiable form: condition, metric, and threshold.
2. Pick the smallest local surface that can disprove it.
3. Capture a baseline from the old state: merge base, parent commit, failing branch, or current broken repro. For new code with no old state, the baseline is a negative control: break the input or remove the guard, and show that the same check fails. A green check with no baseline is `INCONCLUSIVE`. Run the control under the exact conditions that the claim states. If a condition is off (for example a compiler feature), turn it on for the control, for example with a temporary change that you revert. A control under other conditions proves only itself. The control must break the mechanism that the claim is about, for example a source mutation that relaxes a memory order or removes a guard. Run a source mutation with `.claude/skills/deliver/scripts/mutate.py`, which restores the file and reports a mutant that does not build. A control that only corrupts the input of the checker proves only the checker. If this machine cannot make the claim fail (for example a memory-order bug on x86), the verdict is `INCONCLUSIVE` and names the manual check that can. A mutation that does not reproduce the failure is a finding: record it, then find the mutation that does. Exception: when no caller can reach the mutated behavior (for example the only caller already runs off the main actor), the mutant is equivalent. Record it as equivalent in `decisions.tsv` with the caller reason, and stop. A probe that measured one effect of the mutant is not a caller reason. A surviving mutant that moves framework setup (a value set before or after an object takes ownership) is an unobserved difference: keep it on the replay list, and check it first when an artifact check of the built app finds a defect. A control from an earlier phase counts only when no later commit changed the code it broke or the test that killed it: `git log <control-commit>..HEAD -- <controlled files> <killing test files>` is empty. Otherwise run the control again with `.claude/skills/deliver/scripts/mutate.py --replay <old log> <new log>`: it reads the mutation, the commands, and `--expect` from the log header. When a later commit changed the old text, the replay exits 2: write that mutant again on purpose. A commit that moves the killing test behind the slow gate takes it out of `make check`. When a control survives, run it again with `DIRIGIBLE_SLOW_TESTS=1`. If only that run kills it, record "guarded only by slow tests" in `decisions.tsv`.
4. Capture treatment from the changed state with the same command, data, warmup, and environment.
5. Compare raw artifacts: numbers, screenshots, terminal transcripts, HTTP responses, profiles, heap snapshots, or test output.
6. Return exactly one verdict: `VERIFIED`, `NOT VERIFIED`, or `INCONCLUSIVE`.

## Local Surfaces

- Code behavior: focused unit/integration tests or a minimal repro script.
- Audio files: `afinfo <file>` for format, channels, sample rate, and duration. `ffprobe -hide_banner <file>` for container facts.
- Audio levels: `ffmpeg -i <file> -af ebur128 -f null -` for integrated loudness (LUFS) and true peak. `ffmpeg -i <file> -af astats -f null -` for RMS, peak, and noise floor.
- Session files: `xmllint --noout <file>` for well-formed XML, then read the actual elements.
- App behavior: launch the bundle with `make run`, then run `scripts/screenshot.sh <out.png>`. It captures only the Dirigible window, never the whole screen. Stop the app afterwards with `pkill -f build/Dirigible.app/Contents/MacOS/Dirigible`. A layer read or an offscreen render (`layer.render(in:)`, `cacheDisplay`) does not show what the window server composites, so it cannot prove a redraw or pixel claim. Prove such a claim with a screenshot of the built app after the real gesture. When the change keeps old pixels (a dirty rect, a redraw policy), also compare that screenshot with one after a forced full redraw of the same state. To drive the app, run `scripts/hid.swift` (a drag, a drag with `--no-up` and then `up` outside the window, a click with `click <x> <y>` and `--right` or `--double`, Esc, Cmd-Z with `key 6 --command`, `--shift` and `--option`, a trackpad scroll with `scroll ... --phases`). Post keys only through it: it presses and releases the modifier keys around a key. A key event with only a modifier flag leaves the modifier held, and every later event of any process, also a test run, gets it. It checks `AXIsProcessTrusted()` first and exits 3 with no trust. A locked screen blocks menus, popovers, HID CGEvents, and the AX window tree; the window capture still works. When `screenshot.sh` warns about the lock, make every interaction check manual, with no HID or AX probe.
- A visual report of the user: first find where it is. Diff a capture after the gesture with a capture after a full redraw, map the box of the changed pixels to view rects, and run the same probe on `main`. A "does not reproduce" result counts only when the probe uses the event path of the user (HID scroll events with phases and momentum, on an unlocked screen) and the content that the user named (for example a real waveform). Else the report stays `INCONCLUSIVE` with a manual check. Another defect that the probe finds gets its own claim; it does not close the report.
- Performance: same-machine baseline and treatment timings, or an Instruments trace from `xcrun xctrace record`.
- Memory: `leaks <pid>` or `footprint <pid>` before and after the suspected operation.

## Artifact Layout

When safe to write artifacts:

```text
./.scratchpads/verify/<claim-slug>/
├── claim.md
├── timeline.md
├── baseline/
├── treatment/
├── diff/
└── verdict.md
```

Each probe run writes to a new folder, named by the commit and a run number. A later run never overwrites the output of an earlier one: a verdict cites only a log that is still on disk.

`.scratchpads/` is gitignored. Recordings of real voices are personal data: keep them there, never commit them.

## Verdict Rules

- `VERIFIED`: baseline and treatment differ in the predicted direction, by the claimed threshold, with no obvious confound.
- `NOT VERIFIED`: the behavior is unchanged, moves the wrong way, or misses the threshold.
- `INCONCLUSIVE`: no valid baseline, noisy signal, failed measurement, or an environment difference invalidates the comparison. This includes a control that cannot fail on this machine, and a code review with no control. A grep or a read of source text is a code review. Prove a file-format claim with the bytes that the old and the new code write for the same input.
- A claim that depends on an open manual check gets no `VERIFIED (M-n)`. Restate the automated part as a narrower claim and give it its own verdict. The manual part is `INCONCLUSIVE` and names the check. The run summary counts these parts.

## Output

Use this shape:

```text
VERIFIED | NOT VERIFIED | INCONCLUSIVE
Claim: <falsifiable claim>

Evidence:
<metric/artifact>: baseline=<...>, treatment=<...>, delta=<...>, threshold=<...>

Reasoning:
<one tight paragraph naming the evidence and any confounds>
```

Do not soften a negative result. A clear `NOT VERIFIED` is useful.
