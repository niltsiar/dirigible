---
name: verify-this
description: "Use for \"verify this\", \"prove it works\", \"did this fix it\", or before a run marks a task done. It proves or disproves one claim from a baseline and a treatment, and returns VERIFIED, NOT VERIFIED, or INCONCLUSIVE."
---

# Verify This

Verification proves or disproves one claim with repeatable evidence: a before/after repro of a bug fix, a measured UI, CLI, API, performance, or memory claim, or the user-visible behavior behind a passing test. For a vague claim ("the code is cleaner"), ask for a measurable claim first.

## Workflow

1. Restate the claim in falsifiable form: condition, metric, and threshold. When the criterion has a word and no number ("opaque", "sharp"), set the number from the intent of the criterion before the first measurement. A number set after a failed measurement changes the criterion: log it in `decisions.tsv` as a change, and add a control that the new number refuses, between the old and the new value.
2. Pick the smallest local surface that can disprove it.
3. Capture a baseline from the old state: merge base, parent commit, failing branch, or current broken repro. For new code with no old state, the baseline is a negative control: break the input or remove the guard, and show that the same check fails. The red-first test log is that baseline. Read `.claude/skills/deliver/references/mutation-controls.md` when you pick or run a mutant. A green check with no baseline is `INCONCLUSIVE`.
4. Capture treatment from the changed state with the same command, data, warmup, and environment.
5. Compare raw artifacts: numbers, screenshots, terminal transcripts, HTTP responses, profiles, heap snapshots, or test output.
6. Return exactly one verdict: `VERIFIED`, `NOT VERIFIED`, or `INCONCLUSIVE`.

## Local Surfaces

- Code behavior: focused tests or a minimal repro script.
- Audio files: `afinfo <file>` for format, channels, sample rate, and duration. `ffprobe -hide_banner <file>` for container facts.
- Audio levels: `ffmpeg -i <file> -af ebur128 -f null -` for integrated loudness (LUFS) and true peak. `ffmpeg -i <file> -af astats -f null -` for RMS, peak, and noise floor.
- Session files: `xmllint --noout <file>`, then read the actual elements. To check an edit with no screen, apply it to a scratch package with the `dirigible` CLI, then read the result with `dirigible info`, `render`, or `export` and `afinfo`. A scratch check that runs `dirigible favorites` sets `DIRIGIBLE_FAVORITES` to a store in the probe folder. Start no CLI build while a test or a bench runs.
- The built app: read `references/driving-the-app.md` when a check launches, drives, or captures the app, when you check a visual report of the user, or when a doc quotes macOS text.
- Performance: same-machine baseline and treatment timings, or an Instruments trace from `xcrun xctrace record`. Compare the benches with main through `scripts/bench-pairs.sh`. Fix the pair count before the runs, and do not pick the clean pairs after the results. A time bar (for example, under 1 s) is `VERIFIED` only when the bar minus the median of the runs is larger than the max-min spread of the runs, else `INCONCLUSIVE`; a median over the bar is `NOT VERIFIED`.
- Memory: `leaks <pid>` or `footprint <pid>` before and after the suspected operation.

## Artifacts

When it is safe to write, put the evidence in `.scratchpads/verify/<claim-slug>/`: `claim.md`, `timeline.md`, `baseline/`, `treatment/`, `diff/`, and `verdict.md`. Each probe run writes to a new folder, named by the commit and a run number, and never overwrites an earlier run: a verdict cites only a log that is still on disk.

## Verdict Rules

- `VERIFIED`: baseline and treatment differ in the predicted direction, by the claimed threshold, with no obvious confound.
- `NOT VERIFIED`: the behavior is unchanged, moves the wrong way, or misses the threshold. Report it plainly.
- `INCONCLUSIVE`: no valid baseline, a noisy signal, a failed measurement, or an environment difference. This includes a code review with no control, and a control that cannot fail on this machine (for example a memory-order bug on x86): name the manual check that can. A grep or a read of source text is a code review.
- Exception: when the claim is about the text of a doc, that text is the artifact. Grep it on main and on the branch, and count the required new sentence and each old phrase.
- Prove a file-format claim with the bytes that the old and the new code write for the same input.
- A verdict on UI that macOS draws names the sampled macOS version, architecture, locale, and setup path (for example, a quarantine value written by hand, not a download). A doc decision for an axis that the run did not sample needs an OS source (a `.loctable` or a man page) or a manual check.
- A claim that depends on an open manual check gets no `VERIFIED (M-n)`. Restate the automated part as a narrower claim and give it its own verdict. The manual part is `INCONCLUSIVE` and names the check. The run summary counts these parts.

## Output

```text
VERIFIED | NOT VERIFIED | INCONCLUSIVE
Claim: <falsifiable claim>

Evidence:
<metric/artifact>: baseline=<...>, treatment=<...>, delta=<...>, threshold=<...>

Reasoning:
<one tight paragraph naming the evidence and any confounds>
```
