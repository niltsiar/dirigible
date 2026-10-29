# 0064. Repair effects: own DSP stages in the clip render, and their origin elements

- Status: accepted
- Date: 2026-10-27
- Accepted: 2026-10-29, after plan gates 1 and 2 of run `2026-10-27-repair-set`.
- Amends: 0054 (the chain has stages before and after the engine; a de-clip keeps the product of its pass scales as a level loss), 0057 (the level rule for a kind with no level; `isUnchanged` for the repair kinds; three origin elements)

## Context

The user asked for a repair set on 2026-10-14: reduce rumble (F98, from Audition), repair clipped peaks (F99, from Audition), and soften harsh "s" sounds (F100, from SoundCraft). Each is a clip render on the path of 0054, with the link of 0057, so a change of a setting replaces its level and Restore Original removes it.

macOS has no de-esser unit and no de-clip unit; it has AUHipass, AUNBandEQ, `AVAudioUnitEQ`, and AUMultibandCompressor (probe on macOS 15.8.1, Intel). `AVAudioUnitEQ` `.highPass` is a 2nd-order Butterworth, equal to an RBJ biquad at Q 0.70711 to 0.01 dB. A de-clip on the output of a high-pass at 80 Hz finds 0 of 541 clipped runs of a voice at 6 dB over, and on the output of AUSoundIsolation it finds 1. An absolute de-ess detector (-30 dBFS, SoundCraft) cuts 19.0 % of the frames of a voice at -6 dBFS and none at -26 dBFS; a detector relative to the full band gives the same result at both levels. An export with no loudness target has no limiter. Reference apps: [research](../research/repair-set.md).

## Decision

**D1. Own DSP stages.** The three effects are `vDSP` and Swift stages of `EffectChain`, not Apple units. The de-clip and the high-pass run on each source block before the player node, in that order; the de-ess runs on each output block after the latency drop and before the scale. Each stage keeps its state across blocks, has a latency in frames, and gives its held frames at the end. Each stage is the identity when it finds nothing to change.

**D2. The chain order.** `Effect` cases, in chain order: declip, rumble, hum, noise, deess. The leveler and voice-match put ride and match after noise and before deess.

**D3. Reduce Rumble.** A 2nd-order Butterworth high-pass (12 dB per octave), RBJ coefficients, at a whole cutoff of 20 to 300 Hz, standard 80 Hz.

**D4. Repair Clipped Peaks.** For each channel: the peak of the run span, read before the chain preload of the render. A candidate is a run of samples of one sign at or over a whole percent of that peak (90 to 100, standard 99). A clipped run is each stretch of 3 or more candidate samples, up to 10 ms long, within max(1e-6 x the run level, 2 LSB of the carried bit depth) of the run level, flat as a clipper leaves them, so a steady tone is not a clip. The carried bit depth is the smallest depth whose step holds each sample of the span: a clip file is a 24-bit WAV, and a 16-bit import keeps its 16 bits in it, so a 16-bit dithered source keeps its runs. It is filled with a cubic from the 4 good samples on each side; a filled sample keeps at least the run level. A run with fewer than 5 good samples on a side in the span stays as it is. The repair does not hold for a lossy codec source or a resampled source: such a clip is not flat, and the de-clip finds no run or few (a call track, an MP3, AAC, or Opus import, a file at another rate). The render scales pass 1 by s1, which puts the filled peak at the import ceiling, and a second pass, for an output still over full scale, runs at s1 x s2. The render does not give the product back as clip gain: the added gain of the origin is 0 dB, and the clip plays 20 log10(s1 x s2) dB quieter. The app banner names the drop in whole dB (the largest drop of the clips, "up to", for two or more clips), or says that no clipped peak was found.

**D5. Soften "S" Sounds.** A split-band de-esser: the high band is a 2nd-order high-pass at a whole frequency of 2,000 to 16,000 Hz (standard 6,000); peak envelopes (attack 0.5 ms, release 60 ms) of the high band and of the full band of the loudest channel give the ratio; the cut is the ratio in dB plus 10, clamped to 0 and to a whole largest cut of 1 to 40 dB (standard 10), and it is 0 while the full-band envelope is under -100 dBFS, so digital silence passes unchanged; the output is the input minus (1 - g) times the high band, with one g for all channels. The 60 ms release holds a cut on a vowel after an "s" for up to 131 ms (a known limit).

**D6. The level rule (0057 D4 amended).** One rule for each requested kind k. A kind with a level gets its new value in that level. A kind with no level joins the lowest level that holds a kind after k in chain order; with no such level, k goes in one new level on top, which each such kind of the request shares. So one request can change two levels, with one undo entry, and bottom to top each kind of a level comes after each kind of the levels below it. `clipRenderPlan` enforces the order; the origin reader refuses no order. `isUnchanged` holds for declip, rumble, and deess too: they read only file samples.
**D7. Format.** `<declip percent>`, `<rumble hz>`, and `<deess hz decibels>` in an `<origin>`, in chain order, from `session.xml` version 14: one version for the three. An origin with one of them makes the file version 14. The reader refuses a value outside its type.

**D8. Commands and the app item.** One command, `dirigible clip repair`, with `--rumble`, `--clipping`, `--sibilance`, and `--sibilance-hz`; one tool, `clip_repair`; one app item, Tools > Repair Sound..., a sheet in the DuckSheet pattern with the button Repair (UI council D1 to D3). Each role is accepted.

**D9. Render guards.** One owner gives the span peak, the carried bit depth, the stages, the pass 1 scale, and the guards to the render and to the preview, so a preview equals the same frames of the render to within the render scale, and each guard holds for both. The owner refuses a filter corner at or over 0.45 x the session rate before any read, with no clamp; the render calls that check with its role check. The render refuses a block with a non-finite sample before its write, and the preview refuses a window before it plays it. The span read of the owner stops at a cancel before each block, and the preview keeps its result for each clip until the span or a setting that changes the peaks changes. Each refusal has its own `ClipRenderError` case and text; the corner text names the highest frequency that the session takes, or, when no value of the effect fits, the lowest session rate that takes it. The owner is `Render/RepairSetup.swift`. The test seams of `renderClips` are internal parameters: `component:` and `readFault:` (0054), `secondPassGain:`, and `addedStage:`, a stage after the post-stages of each chain (a gain, or a NaN).

## Consequences

- A de-clipped clip plays quieter by the scale. The guide says so.
- Repair Clipped Peaks and Reduce Rumble after Reduce Noise render the noise level again from its source. One request can change two levels, with one undo entry.
- The cubic repairs light clipping. Heavy clipping needs an AR or FFT method (a later item). A clip that a resampler or a lossy codec changed is not flat, and the de-clip leaves it as it is: a call track or a compressed import can show "No clipped peaks found." over audible distortion. The sheet and the guide say that the repair finds flat peaks, as in a direct recording.
- A 16-bit tone at full peak at or under 100 Hz (48 kHz) has crests flatter than one 16-bit step, and the de-clip can change them by up to -67.9 dB.
- A session at a low rate (for example 22,050 Hz) refuses a de-ess corner at or over 0.45 x its rate, and a session at 4,444 Hz or less takes no de-ess.
- The shared error texts of a clip render stop naming the noise reduction.
- No platform unit to load, so macOS 14 and Apple silicon run the same code. The DSP numbers are measured on Intel.

## Alternatives

- Apple units in the graph (AVAudioUnitEQ, AUMultibandCompressor). Rejected: two mechanisms, a detector that follows the file level, and no proven identity.
- Three commands and three tools. Rejected: one command with options, as `clip denoise --hum`.
- A new level on top for each kind (0057 as written). Rejected for kinds that come before the lowest level: a de-clip on noise output finds no clip.
- One rule for the whole request (it joins the lowest level only when each requested kind comes before each kind of that level). Rejected: all three repairs on a noise clip become one level on top, and the de-clip finds 1 of 541 runs.
