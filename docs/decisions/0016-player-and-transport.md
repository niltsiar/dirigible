# 0016. Player and transport: our own mix render into one AVAudioPlayerNode, reverse JKL with hold, keys that yield to text

- Status: accepted
- Date: 2026-09-24
- Accepted: 2026-09-24, after plan gates 1 and 2 of the timeline-playback run. The gates added the playhead at open, the feed numbers and the session revision, the take guard, the key forward to the key window, the chunked render with an exclusive move, the J and L hold, and the media check at play start.

## Context

Release 1 run 4a (`docs/requirements/releases.md`) adds playback: a mix of every track at the session rate with track gain and clip gain, a playhead, seek, JKL, and a transport bar. 0002 puts the `Player` (AVAudioEngine) in `DirigibleAudio` and keeps `Studio` as the facade of the app. 0003 says that a missing or short audio file renders as silence and shows a state. The release rules ask for a menu item with a key for each command, and a decision between reverse play and J as skip-back, because `AVAudioPlayerNode` cannot play backward.

Probes on 2026-09-24 (macOS 15.7.9, x86_64, Swift 6.2.4; `.scratchpads/runs/2026-09-24-timeline-playback/probe/output.txt`):

- E1. Consecutive `scheduleBuffer` calls play back to back, sample-exact, in offline manual rendering.
- E1b. A change of `AVAudioPlayerNode.volume` ramps. A gain on a node is not sample-exact.
- E2. The main mixer converts the session rate to the output rate. The player time counts session-rate frames.
- E3. `AVAudioUnitVarispeed` changes the signal at rate 1, and adds 47 frames of delay when bypassed.
- E4. Per-node `scheduleSegment(at:)` places audio at the exact frame, for 16 nodes.
- E5. `stop()` calls the `.dataConsumed` handlers of the buffers that did not play. After `stop()`, the player time is nil.
- E6. A missing file gives `'wht?'` (no own code); a wrong file `'typ?'`; a read at or past the end throws with 0 frames; a truncated WAV opens with its real length; an open file reads after a delete.
- E7, E8, E10. A 0.25 s chunk of 8 tracks reads in less than 0.4 ms. Completion handlers run off the main thread. `engine.start()` takes 30 to 50 ms, 0.23 s cold.
- E9. The loss of a private aggregate output gave no `AVAudioEngineConfigurationChange`, and an output unit set to an aggregate over a virtual device blocked in the HAL.
- K1. A menu item with a plain key (Space, J) takes the key also when it is disabled, and runs no action.
- K2. In an app that is not active, SwiftUI did not update the command items after a state change (inconclusive).
- K3. `keyDown(with:)` on the focused field editor inserts the key.
- H1 (2026-09-26, the plan gate). A local `NSEvent` monitor sees the key-up of J and L while the plain-key menu items run at the key-down. Each auto-repeat key-down runs the menu action again, unless the monitor returns nil for it. With a focused text field, the monitor passes every key. The probe app was never key, so a manual check covers an active app.
- X1 (2026-09-26, the plan gate). `link(2)` gives ENOTSUP on exFAT and FAT. `renamex_np(RENAME_EXCL)` works on APFS and FAT; on exFAT it gives ENOTSUP when the target is absent. An `O_CREAT | O_EXCL` claim, then `rename(2)` over it, works on all three.

## Decision

**Mix.** `MixReader` in `DirigibleAudio/Render/` renders the session mix: stereo float32 at the session rate, clip gain plus track gain in dB as one linear factor, a mono track in both channels at unity (0007), and silence where there is no clip or no media. Each read is clamped to `AVAudioFile.length`. Playback, `dirigible render`, and the export of run 5 use this one render, so they cannot differ.

**Player.** `actor Player` in `DirigibleAudio/Render/` owns one `AVAudioEngine` with one `AVAudioPlayerNode` into the main mixer, on the system default output. It never sets the output device (E9). It starts the engine at each play and stops it at each stop, off the main actor (E10). A play schedules 0.1 s chunks, 3 ahead, and refills from the `.dataConsumed` handler. `Studio` makes the Player at the first transport command. A play awaits the session update before it starts, so it plays the latest session. Only play, stop, seek, and shuttle take a new feed number; the actor ignores a command or a handler with an old number (E5). An edit, undo, or redo sends the session on its own path with a revision and no feed number, so the feed goes on and a play that waits is not dropped. Reverse play renders a chunk forward and flips it. A rate other than 1x (0.5x, 2x, 4x) resamples the chunk by linear interpolation, with tape pitch; `AVAudioUnitVarispeed` is not in the path (E3). Tests run the same graph in offline manual rendering. This amends 0002: the Player is an actor, not `@MainActor`.

**Studio.** `Studio` stays the facade. It adds `playback` (stopped or playing with a direction and a rate), `playhead`, `missingMedia`, `playbackStop`, `perform(TransportCommand)`, and `checkMedia()`. `Studio.transport` does not change. A transport command during a take start, a take, or a finalize does nothing, except Space, which stops a take. Record stops playback and starts the take at the playhead. Every take path accepts Record with no await first: it sets the take-start state and a new feed number before it stops the Player, so no play can start into the take. The Player stop is the first step of the serialized take start, so `settle()` waits for it. The take starts at the Player position only when the Player started the play that Record stopped; else it starts at the playhead. At open, the playhead is the session end, so Record in a reopened session appends. The package does not save the playhead. Until run 4b draws the clips, the transport bar warns while a clip on an armed track holds the playhead. After a finalize that succeeds, the playhead goes to the largest end of the clips of the new files of the take. A punch-in split gives an old file a new clip ID, so a new clip ID does not mark a take clip (code gate 1 item 3). `settle()` stops playback first. Edits, undo, and redo work during play; the next chunks use the new session.

**JKL.** J plays backward. A tap latches: L plays forward; each more L while forward goes up a rate (1x, 2x, 4x); Shift-L plays at 0.5x; J mirrors L; K pauses. A hold of 0.3 s or more plays while held, and the key-up pauses, as Hindenburg does (research: "hold them down to play"; build 2572 ignores auto-repeat). One local key monitor drops the auto-repeat of J, L, and Space (H1) and reads the key-up of J and L; a held Space so acts once (code gate 1 item 8); the menu items keep the keys. The key-up decision reads only the stored key-down, and the release calls the Studio pause directly, with no key forward. The media check runs only when a play starts from stopped, not at each shuttle key. Paused and stopped are one state: the playhead stays where play stopped. "Hold K for fast" (K+J, K+L) is not in Release 1.

**Missing media.** `checkMedia` runs off the main actor at open, after each finalize, at each play start, and at window focus. It stats each pool file first (a missing file has no own open error, E6a), then opens it and compares the rate, the channel count, and the length. The states are `.missing`, `.short(frames)`, and `.unreadable`. A read error during play marks the file `.unreadable`. The window shows the paths in a banner. Run 4b draws the clips.

**Keys.** A Transport menu has: Play or Stop (Space), Stop and Return (Shift-Space), J, K, L, Shift-J, Shift-L, Go to Start (Home), Go to End (End), Previous and Next Clip (Shift-Left, Shift-Right). A menu item with a plain key takes the key also when it is disabled (K1), so these items are never disabled. Each action first reads the key window. When it is not a session window (a panel, an alert), or its first responder is text, the action gives the key event to that first responder (K3) and does nothing else. Record stays Command-R: Hindenburg PRO 2 uses Command-Space (Spotlight) or Control-Space (input source).

**CLI (0011).** `dirigible render <package> --out <file> [--from N] [--to N]` writes the mix as a 32-bit float stereo CAF at the session rate. It renders in chunks into one reused buffer, so the memory does not grow with the range. It writes a temporary file next to `--out`, then moves it with `renamex_np(RENAME_EXCL)`, which never replaces an item. Where that call gives ENOTSUP or EPERM (exFAT, X1), it claims `--out` with `O_CREAT | O_EXCL`, then renames over the claim. So it refuses an output path that exists (exit 2), and a render that fails leaves no `--out`. Every exit removes the temporary file. A missing file gives one warning line on stderr and exit 0. `dirigible info` shows the media state of each file (JSON key `media`).

## Consequences

- 0002 gets an amended line: the Player is an actor in `Render/`.
- 0003 gets an amended line: the missing-media check points and states.
- 0011 gets an amended line: `dirigible render` and the `media` key of `info --json`.
- 0014 gets an amended line: the Transport menu keys, and a take starts at the playhead.
- Each play has 30 to 50 ms of latency for the engine start. Nothing holds the output device while stopped.
- An edit during play is heard within 0.3 s. A rate or direction change restarts the feed with a short gap.
- A plain-key menu item looks enabled while a take records. It does nothing then.
- A headphone unplug is a manual check: the probe did not reproduce the notification.
- A user who holds J or L for 0.3 s or more gets a pause at the release. The threshold is a calibration knob.
- A reopened session loses the playhead of the last visit.
- Run 5 builds `exportMix` on `MixReader`, and adds the mono fold and the missing-media confirm.

## Alternatives considered

- **One player node per track or per clip with `scheduleSegment(at:)`** (E4). Rejected: no clip gain (E1b), no reverse, and a second mix path for export.
- **An `AVAudioSourceNode` with our own ring.** Rejected: our own real-time code, while `scheduleBuffer` is sample-exact (E1).
- **A public Player next to Studio.** Rejected: the app would coordinate two transports.
- **`@MainActor Player`.** Rejected: HAL and file work on the main actor (E10).
- **J as skip-back.** Rejected: reverse is one flip of a rendered chunk.
- **Latched JKL only.** Rejected: Hindenburg JKL plays while held (research), and H1 shows that a key-up monitor works with the menu items.
- **Hold-only JKL.** Rejected: the repeated-L ladder needs a press that stays.
- **Save the playhead in the package.** Rejected: a change of the 0003 format for a value that End sets again.
- **Plain keys in a local event monitor, not in the menu.** Rejected: the release rule asks for a menu item with its key.
- **`AVAudioUnitVarispeed` for the rates.** Rejected: it changes the signal at 1x (E3).
