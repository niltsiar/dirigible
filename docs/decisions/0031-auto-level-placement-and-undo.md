# 0031. Auto-level after the take write, and its own undo entry

- Status: accepted
- Date: 2026-10-03
- Accepted: 2026-10-03, after the architect synthesis of run `2026-10-03-loudness` and plan gates 1 and 2 of run `2026-10-03-auto-level`.
- Amends: 0008 (a clip with no measurement keeps its gain; at stop the take clips of one track share one delta).

## Context

R9 asks for an automatic level of each clip. 0008 gives the rule: `gain = clipTarget - measured`, clamped to ±20 dB, with -16 LUFS for a stereo track and -19 LUFS for a mono track. Two things were open: where the measurement runs relative to the take finalize, and how the user removes an automatic gain. The constraints:

- `Clip.gain` exists, and the mix plays it.
- A take is safe only after its `session.xml` write. A fault of the meter must never lose or block a take.
- Every finalize path (stop, retry, recovery at open, `dirigible take finalize`) goes through `completeTake`, and a placement goes through `completePlacement`.
- No clip gain control exists until run 11. So Undo is the only way in the app to remove a bad gain, for example +20 dB on silence with one cough.

## Decision

**One function.** `autoLevel(clips, mode, of:in:)` in `DirigibleAudio/DSP/` sets the gains. It is sync and never throws. It measures all clips in one pass with `DispatchQueue.concurrentPerform`, so the width is the core count. A clip with no gated block, a missing file, or a read fault keeps its gain. Two modes:

- `.eachClip` measures each clip without its gain and gives it the target.
- `.equallyPerTrack` measures each clip with its gain, joins the blocks of the clips of one track (`Loudness.init(union:)`), and adds one delta to each measured clip of that track. The gain differences between the clips stay.

The stop, Cmd-L, Option-Cmd-L, and `dirigible level` call it, so they give the same number.

**At stop.** `completeTake(level: true)` writes the finalized session as before. Then it levels the take clips with `.equallyPerTrack` and writes again when a gain changed. The take clips are the clips whose file is not in the pool before the finalize, the rule of `takeEnded`: a record over splits an old clip, and its right part gets a new clip ID. One take can break into several segments on one track (0004), so one delta per track keeps the level ratio of the speaker. A failed second write keeps the finalized session and gives no error. Only the stop passes `level: true`. Recovery at open, `retryFinalize`, `completePlacement`, and `dirigible take finalize` do not level, so the meter cannot block a repair path.

**Undo.** `TakeOutcome.placed` holds the session of the first write. `Studio.apply` records it as one entry, then the leveled session as a second entry. `History.edit` records no unchanged session, so a take with no measurement gives one entry. The first Undo after a take removes the level, and the second removes the take.

**Cmd-L.** `Studio.level(clips, mode)` checks that the studio is idle, ends a play, and sets `Transport.leveling`. A `defer` sets `.idle` on every exit. In one turn of the write chain, it stops the Player, measures off the main actor, writes `session.xml` when a gain changed, and records one undo entry. A Quit right after Cmd-L does not lose the level. The app levels each whole clip that the selection touches on the selected tracks (`Marks.clipsToLevel(in:)`). With no selection, Cmd-L does nothing. The two items are in a Tools menu after the Record menu: Auto Level (Command-L) and Auto Level per Track (Option-Command-L).

**CLI.** `dirigible level <package> [<clip>...] [--per-track]` calls `autoLevel` through `editPackage`.

## Consequences

- A stop reads each new WAV a second time: about 0.4 s for each hour of stereo audio. The stop wait for 4 mono clips of 2 h is 5.0 s or less (`make bench FILTER=AutoLevelBenchmark`).
- A crash between the two writes loses only the level. No mark says so; the user presses Cmd-L.
- To remove a take, the user presses Undo two times.
- `concurrentPerform` blocks one thread of the cooperative pool for the stop wait.
- The union of the blocks of one track does not span the gaps between its clips.
- Import levels in run 13 with the same function.

## Alternatives considered

- **The meter inside the segment finalize.** No second read, but a pass-1-only rule and a scale correction in a risk-floor file. Cmd-L would still need a second reader.
- **The level before the one take write.** One write, but a meter trap blocks the take in every repair path.
- **A background job after the save.** A fast stop, but an edit during the job needs a merge.
- **Block powers cached in the package.** A free Cmd-L, but a new persisted format and a stale-cache risk.
- **One undo entry for the take and its level.** Simpler, but no way in the app to keep a take and remove its gain before run 11.
- **A task group per clip.** It needs an async `autoLevel` and an async edit path in the CLI.
