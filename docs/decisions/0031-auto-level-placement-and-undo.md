# 0031. Auto-level after the take write, and its own undo entry

- Status: accepted
- Date: 2026-10-03
- Accepted: 2026-10-03, after the architect synthesis of run `2026-10-03-loudness` and plan gates 1 and 2 of run `2026-10-03-auto-level`.
- Amends: 0008 (a clip with no measurement keeps its gain; at stop the take clips of one track share one delta).
- Amended: 2026-10-12, run 2026-10-12-autolevel-fader. Cmd-L levels every clip with no selection, shows a result banner, and never changes the track fader. A change under 0.05 dB keeps the old gain. `dirigible level` prints a report line on stderr and does not write an unchanged session.
- Amended: 2026-10-26, run `2026-10-13-replace-roomtone-split` (see 0053). The Tools menu has a last group after Duck Music Under Speech, with Split Stereo to Mono (Shift-Command-D). It is off with no stereo clip in the selection, during a take, and during an import, paste, or split run.
- Amended: 2026-10-26, run `2026-10-13-render-denoise` (see 0054). The last Tools group also holds Reduce Noise, after Split Stereo to Mono, with no key. It is on with an idle studio and a selection whose clips of the 0031 rule hold one on a track with no role or the dialogue role. An empty selection dims it.

## Context

R9 asks for an automatic level of each clip. 0008 gives the rule: `gain = clipTarget - measured`, clamped to ±20 dB, with -16 LUFS for a stereo track and -19 LUFS for a mono track. Two things were open: where the measurement runs relative to the take finalize, and how the user removes an automatic gain. The constraints:

- `Clip.gain` exists, and the mix plays it.
- A take is safe only after its `session.xml` write. A fault of the meter must never lose or block a take.
- Every finalize path (stop, retry, recovery at open, `dirigible take finalize`) goes through `completeTake`, and a placement goes through `completePlacement`.
- No clip gain control exists until run 11. So Undo is the only way in the app to remove a bad gain, for example +20 dB on silence with one cough.

## Decision

**One function.** `autoLevel(clips, mode, of:in:)` in `DirigibleAudio/DSP/` sets the gains. It is sync and never throws. It measures all clips in one pass with `DispatchQueue.concurrentPerform`, so the width is the core count. A clip with no gated block, a missing file, or a read fault keeps its gain. A new gain nearer than 0.05 dB to the old gain keeps the old gain, so a second level of the same clips changes nothing. The tolerance is in `autoLevel`, so it applies to each caller: Auto Level, `dirigible level`, the level at take stop, and the level at import. One rule gives no change for a second level with no audio change, for each caller. At take stop and at import, a new gain under 0.05 dB keeps 0 dB, and that difference is too small to hear. Two modes:

- `.eachClip` measures each clip without its gain and gives it the target.
- `.equallyPerTrack` measures each clip with its gain, joins the blocks of the clips of one track (`Loudness.init(union:)`), and adds one delta to each measured clip of that track. The gain differences between the clips stay, unless a gain reaches the ±20 dB limit.

The stop, Cmd-L, Option-Cmd-L, and `dirigible level` call it, so they give the same number.

**At stop.** `completeTake(level: true)` writes the finalized session as before. Then it levels the take clips with `.equallyPerTrack` and writes again when a gain changed. The take clips are the clips whose file is not in the pool before the finalize, `takeClips(of:before:)`, which `takeEnded` also uses: a record over splits an old clip, and its right part gets a new clip ID. One take can break into several segments on one track (0004), so one delta per track keeps the level ratio of the speaker. A failed second write keeps the finalized session and gives no error. Only the stop passes `level: true`. Recovery at open, `retryFinalize`, `completePlacement`, and `dirigible take finalize` do not level, so the meter cannot block a repair path.

**Undo.** `TakeOutcome.beforeLevel` holds the session of the first write. `Studio.apply` records it as one entry, then the leveled session as a second entry. `History.edit` records no unchanged session, so a take with no measurement gives one entry. The first Undo after a take removes the level, and the second removes the take.

**Cmd-L.** `Studio.level(clips, mode)` checks that the studio is idle, ends a play, and sets `Transport.leveling`. A `defer` sets `.idle` on every exit. In one turn of the write chain, it stops the Player, measures off the main actor, writes `session.xml` when a gain changed, and records one undo entry. A Quit right after Cmd-L does not lose the level. A level that changes no gain writes nothing and records no entry. The app levels the clips of `Selection.clipsToLevel(in:)`, which gives nil only for the empty selection (no range and no selected track):

- The empty selection: every clip of the session, also on a muted track (0039). The items are then Auto Level All Clips and Auto Level per Track (All).
- A track-only selection: every clip of its tracks.
- A range: each whole clip that it touches on the selected tracks. With no selected track, it uses all tracks, as I, O, and Split do (0018).
- A clip set: its clips.
- A selection with no clip (a gap, a track with no clip, or tracks or clips that an undo removed): Cmd-L beeps and changes nothing (0038).

The two items are in a Tools menu after the Record menu: Auto Level (Command-L) and Auto Level per Track (Option-Command-L). They are off when the session has no clip, during an import, and when the studio is not idle. `Studio.level` returns a `LevelReport`: the changed clips, the clips at the 20 dB limit (changed or not), and the clips with no measurement. The app shows it in a banner after each press, with a new banner key for each press, so VoiceOver reads each result. When no clip changed, the banner says that the track volume does not change the clip gain. Each press removes the old banner first. Auto Level never reads or changes the track volume: the track volume adds to the clip gain, as clip gain does in Pro Tools and Logic (`docs/research/auto-level-reference-apps.md`).

**CLI.** `dirigible level <package> [<clip>...] [--per-track]` calls `autoLevel` through `editPackage`. It prints one line for each clip on stdout, then the report as one line on stderr, with no track volume sentence. When no gain changed, it does not write `session.xml` (`editPackage(writeUnchanged: false)`). This is an exception to the 0011 **Grammar** rule for `dirigible level` only; the other edit commands still write.

## Consequences

- A stop reads each new WAV a second time: about 0.4 s for each hour of stereo audio. The stop wait for 4 mono clips of 2 h is 5.0 s or less (`make bench FILTER=AutoLevelBenchmark`). The budget is for warm reads on the internal disk: a cold read or an external disk adds to it.
- Every stop levels: a Quit, a window close, and the disk-low stop too. So the Quit wait during a take grows by the measurement time.
- A crash between the two writes loses only the level. No mark says so; the user presses Cmd-L.
- To remove a take, the user presses Undo two times.
- `concurrentPerform` blocks one thread of the cooperative pool for the stop wait.
- The union of the blocks of one track does not span the gaps between its clips.
- Import levels in run 13 with the same function. An import and its level are one undo entry (0040).

## Alternatives considered

- **The meter inside the segment finalize.** No second read, but a pass-1-only rule and a scale correction in a risk-floor file. Cmd-L would still need a second reader.
- **The level before the one take write.** One write, but a meter trap blocks the take in every repair path.
- **A background job after the save.** A fast stop, but an edit during the job needs a merge.
- **Block powers cached in the package.** A free Cmd-L, but a new persisted format and a stale-cache risk.
- **One undo entry for the take and its level.** Simpler, but no way in the app to keep a take and remove its gain before run 11.
- **A task group per clip.** It needs an async `autoLevel` and an async edit path in the CLI.
