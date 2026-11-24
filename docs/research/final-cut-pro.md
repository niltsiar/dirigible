# Final Cut Pro editing features for a podcast editor

Date: 2026-09-27

This document records the editing features of Final Cut Pro for Mac (FCP X, 10.x, 11.x, and 12.x) that a podcast editor can use. It maps each feature to the Dirigible model and says keep, adapt, or skip. It answers one question for the Release 2 run of F20 (ripple edit): how can the magnetic timeline and connected clips inform a ripple edit on a multitrack podcast session? It then proposes new feature IDs after F67 of `docs/research/podcast-features.md`.

The sources are the Apple Final Cut Pro User Guide for Mac, the Final Cut Pro release notes, and the FCPXML DTD. A fetch tool read the guide pages and returned their text, partly as a summary. A quote in this document is the text that the tool returned. A claim that no primary source confirms has the mark "(unconfirmed)". A sentence that starts with "Inference:" is our reading of the sources. The value (1 to 5) and effort (S, M, L) of a new ID are our estimates, on the scale of the catalog.

## 1. The magnetic timeline

- **Primary storyline.** "At the heart of the Magnetic Timeline is the primary storyline, where you place your main video and audio clips, such as primary visuals, dialogue, and voiceover" [MT].
- **Ripple on each edit.** "When you insert, trim, or move clips in the primary storyline, surrounding clips automatically move out of the way or snap together to avoid unwanted gaps and collisions" [MT].
- **Move.** When the user drags clips horizontally, "Final Cut Pro ripples clips (and any connected clips) in the timeline to make room for the repositioned clips and to close the gap left by the clips that were repositioned" [AR].
- **Delete.** Delete removes the selected clips, and "any clips to the right of the selection ripple to close the resulting gap" [RM].
- **Replace with Gap.** Shift-Delete replaces the selection with a gap clip. It "preserves connected clips" and keeps the project duration [RM].
- **Trim.** "The default type of trim in Final Cut Pro is a ripple edit." "The change in the clip's duration ripples outward, moving all subsequent clips earlier or later in the timeline" [TR] [PE].
- **Position tool.** P selects the Position tool. A hold of P selects it until the key goes up. With it, "the moved clip overwrites any clips at the new position", and gap clips fill the vacated parts of the primary storyline [AR].
- **Gap clips.** "A gap clip is an empty place in the timeline that you can use to preserve timing and save a spot for a clip you plan to add later" [MT]. In FCPXML, "A 'gap' element defines a placeholder with no associated media" and "Gaps cannot be anchored to other objects" [DTD].
- **Spine.** In FCPXML, "A 'spine' is a container for elements ordered serially in time" [DTD]. Inference: a clip in the primary storyline has no start of its own. Its start is the sum of the durations before it. That is why a delete, an insert, or a trim ripples.

## 2. Connected clips and connected storylines

- **Connected clips.** "Connected clips remain attached and synced until you explicitly move or remove them" [CC]. Music and sound effects connect below the primary storyline [MT].
- **Connection point.** "Connected clips and storylines are connected to the primary storyline at their first frame, but you can move the connection point." Option-Command-click on the connected clip sets a new connection point [CC].
- **Ride with the anchor.** "When you rearrange, move, ripple, or delete clips in the primary storyline, any clips connected to them are moved or deleted along with the primary storyline clips" [CC]. This is the "magnetic link" that the user remembers.
- **Override.** A hold of the Grave Accent (`) key during a drag, a trim, or a delete edits the primary clip and leaves its connected clips where they are [CC] [RM].
- **Range delete.** When a delete removes a range that has connected content, "the connected items are not deleted but are instead shifted to the closest primary storyline clip" [RM].
- **FCPXML.** An anchored item has a `lane` and an `offset`. "0 = contained inside its parent (default)", ">0 = anchored above its parent", "<0 = anchored below its parent". "The 'offset' attribute defines the location of the object in the parent timeline" [DTD]. Inference: the connection is stored data. It is not a view rule.
- **Connected storylines.** "Storylines are sequences of clips connected to the primary storyline". Command-G makes one from two or more connected clips and adds gap clips where needed [SL]. FCP 10.7 (2023-11-30) can "combine a selected group of connected clips into a connected storyline" [RN].
- **Select with connected media.** FCP 11.1 (2025-03-27) can "select a primary storyline clip and all its connected media simultaneously" [RN].

## 3. Trims, blade, range, skimming

- **Roll.** A roll edit moves the edit point between two adjacent clips. "No clips move in the timeline as a result", and the project duration stays the same [RO].
- **Slip.** A slip edit "doesn't change a clip's position or duration in the timeline, but instead changes what portion of the clip's media appears" [SP].
- **Slide.** A slide edit moves a clip between two other clips "without creating a gap" (Option-drag with the Trim tool) [SD].
- **Precision editor.** A double-click on an edit point opens an expanded view of the outgoing and incoming clips and their unused media [PE]. FCP 12.3 (2026-06-30) adds "a persistent two-up display that stays locked in view while you're trimming" with keys [RN].
- **Trim keys.** T selects the Trim tool. Option-[ and Option-] trim the start and the end. Option-\ trims to the selection. Shift-X extends the edit. Comma and period nudge an edit point by one frame, with Shift ten frames [TR].
- **Blade.** B selects the Blade tool. Command-B cuts the selected clips at the skimmer, also during playback. Shift-Command-B (Blade All) cuts "all primary storyline and connected clips" at the skimmer or the playhead [BL].
- **Through edit.** A cut shows a dotted line, a "through edit": the media is continuous on both sides. Trim > Join Clips (or Delete) removes it [BL].
- **Range selection.** R selects the Range Selection tool. A drag can span several clips. I and O set the start and the end, Option-I and Option-O remove them, and X sets the range to the clip under the skimmer [RS].
- **Nudge a clip.** Comma and period move a clip one frame. For audio there are subframe steps with Option [AR].
- **Skimming.** With skimming on, "the content under the pointer plays in the viewer". S toggles skimming, Shift-S audio skimming, and Option-Command-S clip skimming [SK]. The skimmer is a red line, separate from the playhead [SK].

## 4. Roles, audio lanes, and the timeline index

- **Roles.** Roles are "metadata text and color labels that you assign to clips". The default roles include Dialogue, Music, and Effects. The user can make subroles and new roles [RL].
- **Audio lanes.** "Show Audio Lanes" in the Roles pane of the timeline index shows each audio role in "separate, visually distinct layers in the timeline". The lanes follow the role order of the index [AL]. Audio lanes came in FCP 10.3 [RN].
- **Role colors.** FCP 10.7 shows "both video and audio role colors" [RN].
- **Export stems.** The user can export "a project's dialogue, music, and sound effects as separate media files" by role. The choices include a multitrack QuickTime movie and "Audio Only as Separate Files". Each output can be mono, stereo, or surround [ER].
- **Timeline index.** Shift-Command-2 opens a list of the clips (in time order), the tags (standard markers, chapter markers, to-do items), and the roles of the project. "When you select an item in the timeline index, the playhead automatically moves to the beginning of the item." Command-F searches it [IX]. FCP 10.8 (2024-06-20) adds filters for clips with audio effects [RN].

## 5. Markers and chapters

- M adds a marker. A double-click on the marker and the Chapter Marker button make it a chapter marker (orange) [MK].
- "Markers are attached to clips and move with them" [MK]. FCP 11.1 lets the user drag a marker in a clip, or drag it out of the clip to remove it [RN].
- Chapter markers go into the exported media. The apps that recognize them include "podcast apps" and QuickTime Player [MK].

## 6. Audio: volume, fades, crossfades, enhancements

- **Volume line.** The user drags "the volume control (the horizontal line across the audio waveform)" up or down, and the dB value shows [VO].
- **Volume keys.** Control-Plus and Control-Minus change the volume by 1 dB. There are absolute and relative modes, Silence (-∞ dB), and Reset (0 dB) [VO].
- **Range volume.** A volume change on a range from the Range Selection tool adds keyframes at the range edges automatically. The guide names ducking as a use [VO].
- **Keyframes.** Option-click on the volume line, or Option-K, adds a keyframe. Between two keyframes of different values, the line slopes [KF].
- **Fade handles.** "Fade handles appear in the top-left and top-right corners of the audio waveform when you place the pointer over the clip." A drag of a handle sets the fade [FA].
- **Fade shapes.** A Control-click on a handle gives Linear, S-curve, +3dB (the default), and -3dB [FA].
- **Apply Fades.** Modify > Adjust Audio Fades > Apply Fades fades both ends of the selected clips. "The default duration for fades is one half-second", set in the Editing settings [FA].
- **Crossfade.** Option-T on two adjacent clips "creates the crossfade at the edit point between the selected clips using media handles". Without enough handles, FCP offers "the option to overlap media in your project". The Editing settings set the crossfade duration [XF].
- **Enhancements.** Option-Command-A (Modify > Enhance Audio) analyzes a clip. The enhancements are Loudness ("improves the main audio signal and makes it more uniform", with Amount and Uniformity), Noise Removal, Hum Removal ("at either 50 or 60 Hz"), Voice Isolation ("prioritizes human voices over other parts of the audio signal"), and Equalization presets [EN].
- **Voice Isolation warning.** Voice Isolation on several components that play at the same time "may result in garbled audio" [EN]. The first FCP version with Voice Isolation is unconfirmed: two reads of [RN] gave different answers.
- **Per component.** An enhancement acts on one audio component. For a dual mono clip, the user selects one component first [EN].

## 7. Sync by audio, multicam, and clip containers

- **Synchronize Clips.** Clip > Synchronize Clips (Option-Command-G) makes a synchronized compound clip. "Use audio for synchronization" aligns the clips by their audio waveforms. "Some audio recordings are not suited for use with this feature", and it "may result in long processing times" [SY].
- **Multicam.** A multicam clip syncs its angles by audio, by timecode, or by the content-created date (1-second accuracy) [MC]. No source says that FCP corrects a clock drift between two recorders (unconfirmed).
- **Compound clips** group clips and nest them. An edit of a compound clip changes the parent, and "all of its child clips" inherit it [CP].
- **Auditions** are "a set of alternative clips" in one place of the timeline (Command-Y) [AU].
- **Break Apart Clip Items** (Shift-Command-G) turns a compound clip or an audition back into its clips [CP2] [AU].

## 8. Recent additions, 2023 to 2026

Only the additions that touch audio or timeline editing [RN]:

- 10.7 (2023-11-30): the timeline scrolls to keep the playhead in view; connected clips to a connected storyline; role colors.
- 10.8 (2024-06-20): a toolbar button for timeline scrolling; timeline index filters.
- 11.0 (2024-11-13): Transcribe to Captions "from spoken audio in the timeline"; faster timelines with many markers.
- 11.1 (2025-03-27): drag a marker in a clip; select a primary clip with its connected media; Transcribe to Captions on one audio role component.
- 12.0 (2026-01-28): Transcript Search finds "spoken words or phrases" in the footage.
- 12.3 (2026-06-30): the two-up trim display; a key that swaps clip positions in the primary storyline; Generate Captions.
- Enhance Light and Color (10.8) is a video effect. It does not apply to Dirigible.

## 9. Mapping to Dirigible

The Dirigible model (0003): a session has tracks. A track holds clips at absolute frame positions. Clips on one track never overlap, and a placed clip overwrites the clips under it. Markers belong to the session, not to a clip. All tracks of one take share one time axis through the capture timing (F03). There is no primary storyline and no gap object.

| Feature | FCP behavior | Dirigible mapping | Keep/Adapt/Skip | Why | Source |
|---|---|---|---|---|---|
| Primary storyline (spine) | Clip starts are the sum of the clip durations before them | Absolute starts per clip; no spine | Skip | A multitrack podcast has no single main track. The host and the guest tracks are peers, and a spine on one track breaks the sync of the others | [MT] [DTD] |
| Magnetic ripple on delete | Delete closes the gap; later clips and their connected clips move | Ripple Delete of a range on a set of tracks (section 10) | Adapt | F20. Ripple the time axis across tracks, not one track | [RM] [CC] |
| Ripple on insert | Insert pushes later clips | Ripple Insert (paste insert) on a set of tracks | Adapt | F20, like Hindenburg Insert (Cmd-I) | [MT] |
| Ripple on move | A drag reorders clips in the storyline | Move stays an overwrite | Skip | A reorder on one track moves speech away from the other tracks | [AR] |
| Ripple trim (default trim) | An edge drag moves all later clips | Edge drag with a modifier ripples the tracks in scope (F68) | Adapt | The Release 1 trim stays the default, because a plain edge drag would then cut or insert time on every track | [TR] |
| Position tool | Move overwrites; gap clips fill the old place | The Release 1 move (0003 overwrite rule, 0020) | Keep | Dirigible already works this way | [AR] |
| Gap clips | An empty clip object that keeps timing | Empty time between clips; no object | Skip | Absolute starts keep the timing without an object | [MT] [DTD] |
| Replace with Gap (Shift-Delete) | Delete with no ripple | The Release 1 Delete (0018) | Keep | Same behavior; the F20 run picks the key of Ripple Delete | [RM] |
| Connected clips | A clip anchored to a primary clip moves and is deleted with it; the ` key overrides | A clip anchored to a clip on another track (F71) | Adapt, later | Useful for a jingle or a sound effect tied to a line of speech. It needs stored data and new rules for overwrite | [CC] [DTD] |
| Connected storylines | A group of connected clips with its own ripple | No mapping | Skip | Track groups (F24) cover the need | [SL] |
| Roles and subroles | Labels and colors on clips | A role per track (F72, done) | Adapt | A Dirigible track already holds one kind of audio. A role on the track drives auto-level targets, ducking, and stems | [RL] |
| Audio lanes by role | Clips of one role in one lane | Tracks are the lanes | Skip | Dirigible tracks already show this | [AL] |
| Export stems by role | One file per role, or a multitrack file | Stem export per track or per role (F73) | Adapt | Podcasters hand stems to a mixer or a video editor | [ER] |
| Auditions | Alternative clips in one place | No mapping | Skip | Rare in podcasts; undo and duplicate tracks cover a take comparison | [AU] |
| Compound clips | Nested clips with one parent | No mapping | Skip | A nested model breaks the flat track model of 0003; F24 groups cover the need | [CP] |
| Break Apart Clip Items | Undo a compound clip or an audition | No mapping | Skip | Depends on the two rows above | [CP2] |
| Precision editor | Expanded view of an edit point | No mapping | Skip | A video trim view; roll and slip give the audio value (F69) | [PE] |
| Roll, slip, slide | Trims that keep the duration | Roll and slip (F69) | Adapt | Hindenburg shuffle trim and slide do the same (mouse-edits.md section 4) | [RO] [SP] [SD] |
| Clip and audio skimming | Audio plays under the pointer | No mapping now | Skip | JKL (F17) and click-to-seek cover it; audio scrub needs its own player design | [SK] |
| Range selection | R tool; I and O; X for the clip | Marks with Set In and Set Out (0018) | Keep | Dirigible already has it | [RS] |
| Blade and Blade All | Cut at the skimmer; Shift-Command-B cuts all tracks | Split (Cmd-B); with no track selected it splits all tracks (0018) | Keep | Dirigible already has it | [BL] |
| Join through edit | Delete on a through edit joins the clips | Join two clips of one file with continuous offsets | Adapt | Part of F24 merge; no format change | [BL] |
| Markers attached to clips | A marker moves and is deleted with its clip | Session markers; a ripple shifts them (section 10) | Adapt | A marker on the time axis is simpler, and a chapter must not go away with a clip | [MK] |
| Chapter markers in export | Chapters go into the media; podcast apps read them | F56 | Keep | Same goal as Hindenburg | [MK] |
| Volume line and 1 dB keys | Drag the line; Control-Plus and Control-Minus | F31 clip gain with a line and keys | Keep | Direct and fast | [VO] |
| Range volume with keyframes | A range change adds keyframes at its edges | F31 by split at the range edges (no format change); ramps by F75 | Adapt | Release 2 can split and set clip gain; ramps need an envelope (state on 2026-11-24: F31 and F75 are done, `docs/requirements/features.md`) | [VO] [KF] |
| Volume keyframes | Option-click adds a keyframe; the line slopes | Gain envelope per clip (F75) | Adapt | Needed for ducking (F34) | [KF] |
| Fade handles | Corner handles; four shapes; +3dB default; 0.5 s default | F32 with corner handles, shapes, and a default length | Keep | Same as Hindenburg corner handles | [FA] |
| Crossfade (Option-T) | Crossfade at the edit from media handles, or an overlap | F33: a crossfade that reads the handles past each clip end | Adapt | Clips on a track must not overlap (0003), so read the handles and do not overlap the clips | [XF] |
| Loudness enhancement | Compression with Amount and Uniformity | F36 compressor and F30 auto-level | Adapt | Split into the loudness engine (0008) and a compressor | [EN] |
| Noise Removal, Voice Isolation | ML noise and voice processing per component | F35 (R8, 0009) | Adapt | Same need; the method is a 0009 decision | [EN] |
| Hum Removal | 50 or 60 Hz | Hum removal per track (F77) | Adapt | Cheap notch filters; a common fault of cheap mixers | [EN] |
| Synchronize Clips by audio | Aligns clips by waveform | Sync a clip to another track by waveform (F74) | Adapt | A double-ender file from a remote guest needs this | [SY] |
| Multicam | Angles synced by audio or timecode | No mapping | Skip | Video angle switching; F74 gives the audio part | [MC] |
| Timeline index | List of clips, markers, chapters, roles; search; select seeks | Session index (F76) | Adapt | Hindenburg has Markers and Chapters lists too | [IX] |
| Clip appearance | Clip height; waveform size (Control-Option-Up and Down) | Waveform vertical zoom (F78) | Adapt | Quiet speech is hard to see; the lanes already fit 40 to 200 pt | [CA] |
| Timeline scrolling (10.7) | The view follows the playhead | Follow scroll (0022) | Keep | Dirigible already has it | [RN] |
| Transcribe to Captions, Transcript Search | Captions and word search from audio | F27 | Keep, later | Same place as the catalog | [RN] |
| Solo and mute a clip | Per clip | Not researched here | - | Out of the scope of this document | - |

## 10. Ripple edit for Release 2 (F20)

The rules that Dirigible chose are in `docs/decisions/0037-ripple-edit.md`, with the research in `docs/research/ripple-edit.md`.

### What FCP teaches

- FCP ripples one spine. The spine is safe to ripple because every other clip rides on it through a connection [MT] [CC].
- A range delete does not cut a connected clip. It shifts the connected clip to the closest primary clip [RM].
- The user can always override the link for one edit (the ` key) [CC].

### What differs in Dirigible

- A podcast session has two or more speech tracks from one take, and music and effects tracks. No track is the spine.
- Inference: the time axis of the take is the spine. A ripple must act on a time range across tracks. A ripple on one track moves the host away from the guest.

### Proposed rules

1. **Scope.** A ripple acts on all tracks by default, whatever the track selection. Only an explicit act limits the scope, for example a modifier that limits the ripple to the selected tracks. The Split rule of 0018 (the selected tracks) does not apply: a clip click selects one track, so a ripple on the selection would move the host away from the guest on the most common gesture. Tracks outside the scope do not change. Test: a clip click, then Ripple Delete, keeps every track in sync.
2. **Ripple Delete of a range R.** On each scope track, clear R (split the clips at the edges of R), then move each clip that starts at or after the end of R to the left by the length of R. The clip IDs follow the 0003 split rule. With all tracks in scope, the tracks stay in sync.
3. **Ripple Insert at a frame p.** On each scope track, split at p, move each clip at or after p to the right by the inserted length, then paste. An insert of silence is the same edit with no paste.
4. **Ripple trim (F68).** A trim with a modifier is a Ripple Delete (shorter) or an insert of silence (longer) of the trimmed span on the scope tracks. The default trim stays the Release 1 trim.
5. **Markers.** With all tracks in scope, a marker at or after the end of R moves left by the length of R. A marker inside R moves to the start of R, so a chapter does not go away without notice. With some tracks in scope, the markers do not move. Conflict: when the music track is out of scope, the speech moves and the chapters stay, so the chapters no longer match the speech. The ripple run decides the marker rule with this input. The session format had no speech role on 2026-09-27 (F72, track roles, was not built; state on 2026-11-24: F72 is done, Release 4 run 9), so the rule can use only tracks and markers, for example: markers follow the ripple in every scope, or the user chooses at the edit. Test: a ripple with the music track out of scope, then the literal marker frames in the session. The chapters export run adds a test that exports the chapters of a rippled session. Hindenburg had a bug with Insert and markers (edit-commands.md section 8), so the tests must cover markers.
6. **One undo step, one Core edit.** Each ripple is one bulk `Session` edit with one taken-ID set (0018 P4), and one `dirigible` command (0011). The mouse ripple trim uses the same edit through the 0020 commit.
7. **Keys.** FCP uses Delete for the ripple and Shift-Delete for the gap [RM]. Hindenburg Cut closes the gap and Clear leaves it (F20 in the catalog). Release 1 Delete leaves a gap (0018). The F20 run picks the keys. Keep Delete as it is, so a Release 1 user does not lose sync by habit.

### The music bed problem

A Ripple Delete on all tracks cuts a music bed under the removed range, and the music jumps. FCP does not cut a connected clip in a range delete [RM]. Three answers, from simple to full:

- **(a) Scope by an explicit act.** The user leaves the music track out of the scope with a modifier (rule 1). No format change. A stored "exclude from ripple" flag on a track is user data and needs a format change. Release 2.
- **(b) Follow tracks (F70).** A track attribute says "follow": in a ripple, its clips move whole and never split. A clip that starts at or after the cut moves; a clip over the cut stays. Format change: one track attribute.
- **(c) Connected clips (F71).** A clip anchored to a clip on another track moves with it and is removed with it. The ` key override applies. Format change: an anchor on the clip. The overwrite rule of 0003 must say what happens when an anchored clip lands on another clip.

Recommendation: Release 2 does (a) with the rules above. Rule 5 then decides where the markers go. (b) and (c) wait for user feedback after Release 2.

### Format change or UI behavior

| Part | 0003 format change | Why |
|---|---|---|
| Ripple Delete, Ripple Insert, ripple trim, marker shift, scope | No | They change only clip starts, lengths, offsets, IDs, and marker positions, which version 1 already stores |
| Roll and slip (F69), join through edit | No | The same fields |
| Sync by waveform (F74), session index (F76), waveform zoom (F78), stem export (F73) | No | A clip start, a view state, or an export option |
| Fades, fade shapes, crossfades (F32, F33) | Yes | New clip attributes; 0003 already plans them |
| Gain envelope (F75) | Yes | New points per clip |
| Follow track (F70), track role (F72), hum removal (F77) | Yes | New track attributes or a stored effect |
| Connected clips (F71) | Yes | An anchor on a clip, plus new edit rules |

0003 raises the version for each new element or attribute with user data. The Release 2 rules in `docs/requirements/releases.md` set the version rule: each run that adds user data raises the version, and the writer writes the lowest version that holds the data of the session.

## 11. Proposed new feature IDs

The value, effort, and release are our estimates.

| ID | Feature | Area | Value | Effort | Release | 0003 change | Source |
|---|---|---|---|---|---|---|---|
| F68 | Ripple trim: an edge drag with a modifier ripples the scope tracks | edit | 4 | S | 2 | No | [TR] |
| F69 | Roll and slip trims | edit | 3 | S | 3 | No | [RO] [SP] |
| F70 | Follow track: in a ripple, its clips move whole and never split | edit | 3 | S | 3 | Yes | [RM] |
| F71 | Connected clips: a clip anchored to a clip on another track | edit | 3 | L | Later | Yes | [CC] [DTD] |
| F72 | Track role (dialogue, music, effects) with a color | project | 3 | S | 3 | Yes | [RL] |
| F73 | Stem export: one file per track or per role, all from the same start | export | 3 | S | 3 | No | [ER] |
| F74 | Sync a clip to another track by its audio waveform | edit | 4 | M | 3 | No | [SY] |
| F75 | Gain envelope per clip; a range gain makes ramps | process | 4 | M | 3 | Yes | [KF] [VO] |
| F76 | Session index: a list of clips, markers, and chapters with search | edit | 3 | S | 3 | No | [IX] |
| F77 | Hum removal at 50 or 60 Hz | process | 3 | S | 3 | Yes | [EN] |
| F78 | Waveform vertical zoom | edit | 3 | S | 3 | No | [CA] |

Notes:

- State on 2026-11-24: the Release column of the table is an estimate of 2026-09-27. `docs/requirements/features.md` holds the landed releases (for example F72 is done in Release 4 run 9).
- F72 helps F30 (auto-level): 0008 sets one target for all clips, but Hindenburg levels music lower than speech (F30 in the catalog). F72 also names the source of F34 ducking and the groups of F73.
- F74 must handle clock drift between two recorders. No FCP source says how FCP handles drift (unconfirmed). F03 stores the drift data of a Dirigible capture, but an imported file has no capture.
- F74, F73, F68, and F69 each need a `dirigible` command (0011).

## Sources

- [MT] Intro to the Magnetic Timeline: https://support.apple.com/guide/final-cut-pro/intro-to-the-magnetic-timeline-verb8fcfc133/mac
- [CC] Connect clips: https://support.apple.com/guide/final-cut-pro/connect-clips-ver7a77ef9e/mac (read at https://support.apple.com/en-kw/guide/final-cut-pro/ver7a77ef9e/mac)
- [SL] Add storylines: https://support.apple.com/guide/final-cut-pro/add-storylines-ver8e3f1748/mac
- [RM] Remove clips from projects: https://support.apple.com/guide/final-cut-pro/remove-clips-from-projects-verc5d34129/mac
- [AR] Arrange clips in the timeline: https://support.apple.com/guide/final-cut-pro/arrange-clips-in-the-timeline-verc147f195/mac
- [TR] Extend or shorten clips: https://support.apple.com/guide/final-cut-pro/extend-or-shorten-clips-ver9847ec25/mac
- [TI] Intro to trimming: https://support.apple.com/guide/final-cut-pro/intro-to-trimming-ver1632d3c8/mac
- [RO] Make roll edits: https://support.apple.com/guide/final-cut-pro/make-roll-edits-ver1632d9ae/mac
- [SP] Make slip edits: https://support.apple.com/guide/final-cut-pro/make-slip-edits-ver1632d8e4/mac
- [SD] Make slide edits: https://support.apple.com/guide/final-cut-pro/make-slide-edits-ver1632caff/mac
- [PE] Use the precision editor: https://support.apple.com/guide/final-cut-pro/use-the-precision-editor-verc1fac344/mac
- [BL] Cut clips in two: https://support.apple.com/guide/final-cut-pro/cut-clips-in-two-ver4e30479/mac
- [RS] Select ranges: https://support.apple.com/guide/final-cut-pro/select-ranges-ver28cca92/mac
- [SK] Skim media: https://support.apple.com/guide/final-cut-pro/skim-media-vere9ba3609/mac
- [RL] Intro to roles: https://support.apple.com/guide/final-cut-pro/intro-to-roles-verb71cbcbe/mac
- [AL] Organize the timeline with audio lanes: https://support.apple.com/guide/final-cut-pro/organize-the-timeline-with-audio-lanes-verb71cb913/mac
- [ER] Export roles: https://support.apple.com/guide/final-cut-pro/export-roles-verb71cb7e5/mac (read through a search excerpt)
- [IX] View your project in the timeline index: https://support.apple.com/guide/final-cut-pro/view-your-project-in-the-timeline-index-ver4e30596/mac
- [CA] Adjust timeline clip appearance: https://support.apple.com/guide/final-cut-pro/adjust-timeline-clip-appearance-verb8e5d346/mac (read through a search excerpt)
- [MK] Add chapter markers: https://support.apple.com/guide/final-cut-pro/add-chapter-markers-verc9cacc031/mac
- [VO] Adjust volume: https://support.apple.com/guide/final-cut-pro/adjust-volume-verc1fabb77/mac
- [KF] Keyframe audio effects: https://support.apple.com/guide/final-cut-pro/keyframe-audio-effects-ver717f5914/mac (read through a search excerpt)
- [FA] Fade audio in and out: https://support.apple.com/guide/final-cut-pro/fade-audio-in-and-out-ver39580fed/mac
- [XF] Crossfade audio: https://support.apple.com/guide/final-cut-pro/crossfade-audio-ver66d503b23/mac
- [EN] Enhance audio: https://support.apple.com/guide/final-cut-pro/enhance-audio-verc1fab873/mac
- [SY] Sync audio and video: https://support.apple.com/guide/final-cut-pro/sync-audio-and-video-verc1fabc30/mac
- [MC] Create multicam clips: https://support.apple.com/guide/final-cut-pro/create-multicam-clips-ver23c764f1/mac
- [CP] Intro to compound clips: https://support.apple.com/guide/final-cut-pro/intro-to-compound-clips-verbbd3496b/mac
- [CP2] Create compound clips (Break Apart Clip Items): https://support.apple.com/guide/final-cut-pro/create-compound-clips-verca9e8d33/mac (read through a search excerpt)
- [AU] Create auditions: https://support.apple.com/guide/final-cut-pro/create-auditions-verbbd353d6/mac
- [RN] Final Cut Pro release notes: https://support.apple.com/en-us/102825 (also read at https://support.apple.com/en-lamr/102825)
- [DTD] FCPXML Version 1.7 DTD: https://developer.apple.com/library/archive/documentation/Miscellaneous/Conceptual/LegacyDTDsFinalCutPro/FCPXMLDTDv1.7/FCPXMLDTDv1.7.html
- [FX] FCPXML Reference (index page; its body did not load in the fetch tool): https://developer.apple.com/documentation/professional-video-applications/fcpxml-reference
