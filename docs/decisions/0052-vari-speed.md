# 0052. Vari-speed: a speed unit in the Player graph only at speeds other than 1x

- Status: accepted
- Date: 2026-10-13
- Accepted: 2026-10-13, after plan gates 1 and 2 of run `2026-10-13-preroll-varispeed` and probe S6.
- Amends: 0016 (the Player graph, the rates, the position, `AVAudioUnitVarispeed`), 0033 (the meter gate).

## Context

F18 asks to play at a different speed with the pitch kept (Release 3 run 9). The Player renders its own mix into one `AVAudioPlayerNode` (0016). Its shuttle rates (0.5x, 2x, 4x) resample by linear interpolation, with tape pitch. 0016 E3: `AVAudioUnitVarispeed` changes the signal at 1x and adds 47 frames of delay when bypassed. Hindenburg: Period toggles vari-speed, Shift-Period and Shift-Comma change it [HM]. Logic Varispeed Speed Only keeps the pitch [LVS]. Apple has a spectral unit (`AVAudioUnitTimePitch`) and a time-domain unit for voice ('ipto', rate 0.5 to 2) [A-H-APS]. The sources are in `docs/research/preroll-varispeed.md`.

Probes (2026-10-13; `.scratchpads/runs/2026-10-13-preroll-varispeed/probes/output-pitch.txt` and `output-gap.txt`):

- S1. `AVAudioUnitTimePitch` and the voice unit 'ipto' (`kAudioUnitSubType_AUiPodTimeOther` through `AVAudioUnitTimeEffect`) keep a 440 Hz sine at 440 Hz from 0.5x to 2x (3x for the spectral unit).
- S2. CPU per s of output: the voice unit 1.2 to 2.4 ms, the spectral unit 4.4 to 6.2 ms, the direct path 0.1 ms.
- S3. With the unit downstream, the player time counts source frames: player frames per output frame = the speed.
- S4. Both units report latency 0. A burst onset moves from -29 ms (0.5x) to +12 ms (2x) under the voice unit.
- S5. In offline rendering, a rewire of the graph between plays costs 0.4 to 2 ms of CPU, and the 1x path with no unit is bit-exact. This is not the heard gap: a device engine stop and start costs about 0.3 to 0.5 s (0044 P4; pre-roll probe PA2). S6 measures the heard gap.
- S6. The heard gap of a speed change during play, on the built-in speakers, recorded by the built-in microphone (`probes/output-gap.txt`): a reconnect of the unit upstream of the main mixer while the engine runs gives a gap of 10 ms or less; an engine stop, rewire, and start gives 110 to 343 ms (7 of 8 trials). Both give a transient of 12 to 22 dB over the high band of the steady tone, as a seek during play does (5 to 19 dB): a play from the heard frame jumps the phase. A rewire while the node plays stops the node and drops its schedule.

## Decision

- **Speed.** 0.75x to 2x in steps of 0.25. Window state, 1x at open. The app keeps the last speed other than 1x as a preference (default 1.5x). It is the one owner: the window resolves Period, ">", "<", and a pick to one speed before `Studio.changeSpeed(to:)`, so the Studio keeps no copy (code gate 1 item 2).
- **Unit.** The time-domain voice unit 'ipto' (`AVAudioUnitTimeEffect`, rate 0.5 to 2; S1, S2), between the player node and the main mixer, only while the feed speed is not 1x. A play rewires the graph upstream of the main mixer, also while the engine runs (S6). At 1x the graph is the node into the main mixer, bit for bit as before.
- **Which plays.** A play at the shuttle rate 1x (Space, the first L or J) uses the speed. The tape rates (0.5x, 2x, 4x) use no unit. A take and its pre-roll play at 1x.
- **Change.** A speed change during play goes on from the heard frame, as a shuttle change does (0016): the node stops, the graph changes upstream of the main mixer while the engine runs, and the node plays again from the heard frame. The heard gap is 10 ms or less (S6). A change between two speeds other than 1x only sets the rate of the unit, with no new play (S6: no gap, a transient of 0.5 to 8 dB).
- **Position.** The player time counts source frames (S3), so the position keeps its formula, and the latency to subtract is the output latency in output frames x the speed. After a change between two speeds other than 1x, the output frames from before the change keep the old speed until they played, so the playhead does not jump on an output with a large latency (code gate 1 item 3). The output latency is the value of 0016 until the pre-roll record changes it.
- **Meter.** The live loudness meter takes values only at 1x forward (0033).
- **Unit fault.** If the system has no voice unit, the speed control is off and shows 1x, and the Player plays at 1x. The check is a component lookup with no instance, so the main actor loads no audio unit. If the unit refuses the rate, the Player plays at 1x (code gate 1 items 8 and 9). Limit: the control then shows the picked speed, not 1x. No unit on the test Mac refuses a rate (probe cg1-rate-refuse), so no user sees this gap today.
- **Keys.** Transport > Playback Speed: Vari-Speed (Period), Faster (">"), Slower ("<"), and a radio item per speed. A toolbar pop-up `transport.speed` shows the speed. Plain keys yield to a focused text field (0016).
- **CLI (0011).** No command and no MCP tool: the speed changes only the sound for a person (the 0015 and 0044 reason). The export and `dirigible render` ignore the speed.

## Consequences

- 0016 gets an amended line: the speed unit, the rewire at a play, and the position rule.
- 0033 gets an amended line: no meter value at a speed other than 1x.
- A play at a speed other than 1x costs the CPU of the unit (probe).

## Alternatives considered

- **The unit always in the graph, bypassed at 1x.** Rejected: with no unit in a 1x play, the 1x path is bit-exact by construction (S5), and a rewire while the engine runs costs no more than a seek during play (S6).
- **The other Apple unit.** `AVAudioUnitTimePitch` (spectral): rejected for now, about three times the CPU (S2) for music quality that speech does not need. Agent check M3 (pitch track and spectral flux against 1x) can take it with a one-line change.
- **A WSOLA stretch in our own chunk render.** Rejected: our own DSP to test and tune, while an Apple unit is one node.
- **`AVAudioUnitVarispeed`.** Rejected: it changes the pitch (0016 E3).
- **Speed times the shuttle rate.** Rejected: 2x times 4x is too fast to be of use, and the tape rates are for moving through the audio.
