# 0066. The silence tool: one silence plan, one edit, a scan that a stale session stops

- Status: accepted
- Date: 2026-10-28
- Accepted: 2026-10-28, after plan gates 1 and 2 of run `2026-10-28-silence-tool`.
- Amends: 0011 and 0041 (the command `silence-edit` and the tool `silence_edit`), 0051 (the tool list), 0002 (the files of the tool), 0062 (F96 builds on `LevelSeries.silences`: this record says how).

## Context

F26 and F96 (Release 5 item 4): find the long silences of a session, and shorten, mute, mark, or skip each one from a review list. Hindenburg PRO has no such tool, only manual Insert silence and Remove silence (`docs/research/silence.md`, findings 1 to 4). Audacity Truncate Silence cuts the middle of each silence to 0.5 s where all tracks are silent (findings 37 to 40). Audition Diagnostics lists the found silences with Delete, Repair, and Mark (finding 19, second-hand). Descript steps through the found gaps with Shorten and Shorten all (findings 12, 13).

Grounding (run analysis, Grounding in the code): `LevelSeries.silences` is the one silence rule (0062). `Session.rippleDelete(_ ranges:on:)` cuts many ranges in one edit and moves the markers by Rule M (0037). Gain envelopes are on file frames, so a cut changes no point (0060). `Session.changeGain` puts its ramps outside its range. A transcript word shows under the clip that holds its midpoint (0055). `runReadJob` holds a transport while it reads.

Rubric: (1) one owner of each frame rule (the cut, the mute range, the marker frame), shared by the window, the CLI, and the tool; (2) the rules testable with no audio; (3) one undo entry and one save for one Apply; (4) an agent can do each row action with no window; (5) no session schema change; (6) the smallest new public surface.

## Candidates

**A. A silence plan and one Session edit.** `DirigibleCore` gets a checked `SilencePlan` (the rows and the keep) and one mutator `Session.editSilences`. The window, the CLI, and the tool build a plan and call it. Studio gets a scan job and an Apply that checks the scanned session. Score: (1) yes, (2) yes, (3) yes, (4) yes, (5) yes, (6) two types, one mutator, two Studio functions.

**B. No new edit: compose the existing ones.** The window runs `changeGain`, `setMarker`, and `rippleDelete` in one `Studio.edit` closure. An agent calls `clip_gain_range`, `marker_set`, and `clip_ripple_delete`. Score: (1) no: the middle cut, the inner mute range, and the order (marks before the ripple) live in the window and in the head of each agent; (2) only through the window; (3) yes in the window, no for an agent (three calls, three saves, three undo entries in an open window); (4) yes, but each agent must learn the rules; (5) yes; (6) none. Rejected on (1) and (3).

**C. One command that scans and edits.** `silence-edit --shorten-all --keep` reads and edits in one call, as Audacity. Score: (4) no: an agent cannot skip or mark one silence; (2) no: each rule test needs audio. Its one-shot use stays: in the window, Command-A and the Action pop-up set every row, and an agent passes every line of `silences` to `silence_edit`.

## Decision

Candidate A.

- **Plan.** `DirigibleCore/SilencePlan.swift`:

  ```swift
  public struct SilenceEdit: Hashable, Sendable {
      public enum Action: Hashable, Sendable { case shorten, mute, mark(name: String) }
      public let range: Range<Frames>
      public let action: Action
  }

  public struct SilencePlan: Hashable, Sendable {
      public enum Refusal: Error, Equatable {
          case outOfRange(Int), overlap(Int), keepOutOfRange
      }
      public let edits: [SilenceEdit]  // caller order, no overlap
      public let keep: Frames?  // nil: 500 ms at the rate of the edited session
      public init(_ edits: [SilenceEdit], keep: Frames?) throws(Refusal)
      public static func cut(of silence: Range<Frames>, keep: Frames) -> Range<Frames>?  // nil: nothing to remove
      public func keepFrames(sampleRate: Int) -> Frames  // keep, else 500 ms
      public func removesFrames(sampleRate: Int) -> Bool  // true when a shorten cuts a frame
  }

  public enum SilenceWarning: Hashable, Sendable { case word, soundOutsideScan }
  ```

  `outOfRange` and `overlap` hold the 1-based number of the edit in the caller order, so the CLI names the pair. The init refuses a bound outside `0...Frames.limit`, two ranges that overlap (two ranges that touch are accepted), and a keep outside `0...Frames.limit`. It has no sample rate, so the tool runs it at its argument check, with no session.
- **Cut rule.** The cut of a shorten of `s ..< e` is `s + keep / 2 ..< e - (keep - keep / 2)`, with `keep / 2` rounded down: the middle of the silence, as Audacity. Keep 0 cuts the whole silence. `SilencePlan.cut(of:keep:)` is the one owner of this rule: the edit, the warnings, and the summary line of the window call it. A silence of `keep` frames or less gives nil: the edit skips the pair and reports it.
- **Mute rule.** A mute of `s ..< e` is `changeGain(by: -96 dB, in: s + ramp ..< e - ramp, ramp: ramp)` on the mute tracks, with `ramp` 10 ms at the rate of the edited session (`rate / 100`, 1 frame at least, so the windows of two rows never overlap). Its window is 0 at `s` and at `e - 1`, so no frame outside the silence changes. A mute of `2 * ramp` frames or less is skipped and reported. The envelope clamps at -96 dB (`Gain.range`), so a mute is a level bound, not digital silence.
- **Mark rule.** A mark of `s ..< e` adds a marker of kind `.marker` at `(s + e) / 2`, with the name of the edit and a new `MarkerID`.
- **Edit.** `Session.editSilences(_ plan: SilencePlan, muting tracks: [TrackID]) throws(SessionError) -> SilenceResult` works on a copy. It takes a nil keep as 500 ms and the ramp as 10 ms at its own rate, so a plan has no rate to mismatch. It makes each mark first, then all mutes in one `changeGains` pass over each clip (the sum of the windows, one write of each envelope; a row of 2 ramps or less is skipped), then one `rippleDelete` of the cuts on all tracks. So Rule M moves the new markers with the old ones, and the envelopes keep their file frames. A throw changes nothing. `SilenceResult` holds the cuts, the new marker IDs in plan order, the removed frames, and the pair numbers of the skipped pairs. A shorten ripples all tracks (0037 Scope).
- **Warnings.** `Session.silenceEditWarnings(cuts: [Range<Frames>], outside: LevelSeries?, threshold: Gain) -> [Set<SilenceWarning>]` gives, for each cut, `.word` when the cut holds the anchor midpoint of a word on any track, mapped through each clip whose file window holds it (0055: `clip.start + midpoint - clip.offset`), and `.soundOutsideScan` when a window of `outside` over `threshold` meets the cut. It reads no audio. A row with a warning starts as Mark.
- **No crossfade.** A shorten join gets no crossfade (0037 Shift mutator).
- **Fault read.** `checkedMixLevels(of:in:package:range:silence:progress:isCancelled:) throws(CheckedReadError) -> LevelSeries` in `DSP/MixLevels.swift` is the one sequence of 0062 Faults: the media check on `Session.ignoringMuteAndSolo`, then `mixLevels`, then the faults of the read. A range that is empty or past `Frames.limit`, and an empty track set, throw `.badSource`: the function never traps. `public enum CheckedReadError: Error { case check(POSIXError), read(POSIXError), faults([FileID: MediaFault]), badSource }` keeps the step that stopped. `ReadWork.levels` and the scan call it, and each caller keeps its own texts: `ReadWork.failure(_:in:)` maps `.check` to `mediaCheckMessage`, a `.read` of `ECANCELED` to `.cancelled`, another `.read` to `audioReadMessage`, and `.faults` to `faultMessage`; the scan maps both POSIX steps to `.silencesRead(code)`, a read `ECANCELED` to `.silencesCancelled`, and `.faults` to `.silencesFaults`. An internal overload with `open: MediaOpen` (the seam of `MixReader`) passes the open to `checkMedia` and to `mixLevels(...open:)`, the one read that `mixLevels` and the checked read both call, so a test gives an open that fails in each phase.
- **Scan.** `Studio.scanSilences(tracks:range:threshold:minLength:progress:) async throws(StudioError) -> SilenceScan` runs `checkedMixLevels` and `LevelSeries.silences` through `runReadJob` on the new transport case `.findingSilences`. When the scan tracks are not all tracks, it also runs `checkedMixLevels` on the other tracks over the range of the scan series, with no silence edge rule. Its apply step changes nothing, so it records no undo entry. `SilenceScan` holds the silences, the tracks, the threshold, the minimum, the series of the tracks outside the scan (nil when the scan reads all tracks), the least threshold that gives one row when it has no silence, and the scanned `Session`. That threshold is `LevelSeries.quietestRun(minLength:in:) -> WindowLevel?` (Core): over each shortest run of consecutive windows with `minLength` frames or more that meets the scan range, the loudest window of the run; the result is the quietest of those windows, or nil when no run fits. The level of one quiet window (`nearestPause`, case `.noPause`) is not that threshold: a silence needs a whole run at or under the threshold. Errors: `.silencesCancelled`, `.silencesRead(Int32)`, and `.silencesFaults([FileID: MediaFault])` with the file names.
- **Apply.** `Studio.applySilences(_ plan: SilencePlan, scan: SilenceScan) throws(StudioError) -> SilenceResult` refuses with `.silencesStale` when the tracks (IDs, order, gains, clips) or the pool files differ from the scanned session. Mute, solo, track names, roles, markers, the episode, and the transcripts do not count: the frames of the plan do not depend on them, and Rule M moves a new marker. Then it calls `edit(ripple: plan.removesFrames(sampleRate:))` with `editSilences(plan, muting: scan.tracks)`. A plan is a ripple only when a cut removes frames: a Shorten of `keep` frames or less cuts nothing. So a pending or split take refuses a plan that removes frames (`.rippleBlocked`) and allows a plan of mutes, marks, and such shortens, and an Apply is one undo entry and one save. The command, the tool, and a batch step ask the same question of the session that they open, because a nil keep depends on its rate.
- **Defaults.** Threshold -40 dBFS (0062), minimum 1 s, keep 500 ms, ramp 10 ms. The window keeps the keep under the minimum. The command and the tool have no minimum: they take the ranges of a `silences` read. The window keeps the last tracks, threshold, minimum, and keep for the next scan; a settings change after a scan turns Apply off until Scan Again.
- **Window.** Tools > Find Silences... shows the Silences tab of the inspector and scans. `SilenceReview` (app target, as `DuckDraft`) holds the settings of the last scan (tracks, threshold, minimum, keep); the start actions, the summary line, and Apply use that keep (U20). It holds the rows and their actions: Shorten, Mute, Mark, or Skip (no change, no marker; a skipped row is not in the plan). A row starts as Shorten, or as Mark when `silenceEditWarnings` gives a warning for its cut, and shows the reason. The list takes multiple selection, an Action pop-up sets the selected rows, and Delete sets them to Skip. A summary line gives the count of each action, the time removed, and the new session length. Mark names come from the localized "Silence %d". A row click sets the range of its silence, and a scan takes that range as its scope only when the user changed it after the click. The list is out of date, as for a settings change, when `SilenceScan.isCurrent(in:)` is false for the session; the window computes it once for each session revision. Then Apply is off and the lane shade is empty. The shade shows only while the Silences tab shows. Return and Delete with the list as first responder go to the list: Return applies while Apply is on, and Delete sets the selected rows to Skip.
- **Command and tool.** `dirigible silence-edit <package> --from <f> --to <f> --action shorten|mute|mark ... [--keep <frames>] [--track <id>]...`; the three options repeat and pair by order, as `clip ripple-delete`. `--keep` defaults to 500 ms at the session rate; `--track` names the mute tracks, none is all tracks. Mark names are "Silence N" in the order of the mark pairs. `DirigibleMCP/SilenceEditWork.swift` owns the argument rules and the texts of the command and the tool `silence_edit` (from, to, and action as arrays; keep; track). The command help and the tool line say: read `silences` with a `min_length` over the keep, so no pair is skipped. Texts:
  - One line for each pair, in the order of the plan: `shorten\t<from>\t<to>\t<cut from>\t<cut to>`, `mute\t<from>\t<to>`, `mark\t<from>\t<to>\t<marker id>`, or `skipped\t<from>\t<to>\t<action>` for a pair with nothing to change. The frames are those of the session before the edit.
  - A last line `removed <n> frames`.
  - Exit 64 for a refusal of the plan, a count mismatch, or an unknown action word, with `(pair <n>)` for a pair refusal; exit 1 for an unknown track; exit 3 for a shorten under a split take; exit 2 for a `<recording>` (0004). A skipped pair is exit 0.
- **Agent manual.** `silence_edit` is in the tool list only: the core has no room (0051).
- **Format.** No schema change: the edit writes clips, envelope points, and markers. A Mute adds gain envelope points, so the session saves as version 10 or later (`Session.fileVersion`, decision 0060; 11 when a track has a role), and a build before 0060 cannot open it.

## Consequences

- The agent read (`silences`) and the Silences tab give the same silences with the same values, so an agent that reads with `--min-length 1 s` and passes each line to `silence_edit` gets the panel result.
- A shorten cuts every track, also the tracks outside the scan. A row whose cut has sound on a track outside the scan starts as Mark and says so, as Audacity "Truncate tracks independently" warns of lost sync. The command and the tool take explicit frames and have no such check, as `clip_ripple_delete`.
- A word whose midpoint is in a cut no longer shows (0055); the row default of Mark makes that cut an explicit choice.
- A scan of the tracks outside the scan reads their audio a second time, so the scan takes longer when a track is unchecked.
- The texts of `silence-edit` are a contract for agents and scripts: a change of a column is a change of this record.
- `ParityTests` maps `editSilences` to `silence-edit`.

## Alternatives considered

- **Candidates B and C** (above).
- **Mute by `clear`** (Logic Strip Silence splits the region, research 34). Rejected: it splits each clip at both edges of each silence, and the gap gives a hard edge with no ramp.
- **Mute on all tracks.** Rejected: a mute is for the scanned tracks; with all tracks checked it is the same.
- **A range marker.** Rejected: Dirigible markers are points (`Marker` in `Model.swift`).
- **Rescan at Apply.** Rejected for now: the rows that the user chose would move under a new scan with no message. Reverse: rescan and keep the action of each row whose silence still exists.
- **The sample rate in the plan.** Rejected: the tool checks its arguments before it has the session, and a plan made at one rate could apply to a session at another rate.
- **Refuse a pair with nothing to change.** Rejected: the default `min_length` of `silences` and the default keep are both 500 ms, so one silence of 10 windows refused the whole agent call.
- **All buttons (Shorten All, Mute All, Mark All).** Rejected: Shorten All cuts a row that starts as Mark because it holds a word or sound outside the scan (UI council 2026-10-28b).
- **Detection on the dialogue tracks** (the `DuckDraft` default). Rejected: a cut would remove music or effects that play in the silence of the voices; with all tracks, a silence is silent on every track that the cut changes.
