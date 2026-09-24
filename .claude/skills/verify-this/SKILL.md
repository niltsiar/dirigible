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
3. Capture a baseline from the old state: merge base, parent commit, failing branch, or current broken repro. For new code with no old state, the baseline is a negative control: break the input or remove the guard, and show that the same check fails. A green check with no baseline is `INCONCLUSIVE`. Run the control under the exact conditions that the claim states. If a condition is off (for example a compiler feature), turn it on for the control, for example with a temporary change that you revert. A control under other conditions proves only itself.
4. Capture treatment from the changed state with the same command, data, warmup, and environment.
5. Compare raw artifacts: numbers, screenshots, terminal transcripts, HTTP responses, profiles, heap snapshots, or test output.
6. Return exactly one verdict: `VERIFIED`, `NOT VERIFIED`, or `INCONCLUSIVE`.

## Local Surfaces

- Code behavior: focused unit/integration tests or a minimal repro script.
- Audio files: `afinfo <file>` for format, channels, sample rate, and duration. `ffprobe -hide_banner <file>` for container facts.
- Audio levels: `ffmpeg -i <file> -af ebur128 -f null -` for integrated loudness (LUFS) and true peak. `ffmpeg -i <file> -af astats -f null -` for RMS, peak, and noise floor.
- Session files: `xmllint --noout <file>` for well-formed XML, then read the actual elements.
- App behavior: launch the bundle with `make run`, then run `scripts/screenshot.sh <out.png>`. It captures only the Dirigible window, never the whole screen. Stop the app afterwards with `pkill -f build/Dirigible.app/Contents/MacOS/Dirigible`.
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

`.scratchpads/` is gitignored. Recordings of real voices are personal data: keep them there, never commit them.

## Verdict Rules

- `VERIFIED`: baseline and treatment differ in the predicted direction, by the claimed threshold, with no obvious confound.
- `NOT VERIFIED`: the behavior is unchanged, moves the wrong way, or misses the threshold.
- `INCONCLUSIVE`: no valid baseline, noisy signal, failed measurement, or an environment difference invalidates the comparison.

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
