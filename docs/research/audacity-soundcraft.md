# Research: Audacity and SoundCraft for Replace, room tone, Duplicate, and Split Stereo

Date: 2026-10-13

## Summary

- Audacity Paste over a selection replaces it, and the track length changes by the length difference, as in the Hindenburg Replace.
- Audacity Duplicate (Command-D) makes a new track at the same time position.
- Audacity has "Split Stereo to Mono": two new mono tracks, both pan center. "Split Stereo Track" gives a left and a right track, pan hard left and hard right.
- Audacity has no room-tone fill. Silence Audio (Command-L) puts digital silence in the selection.
- SoundCraft (storytold/soundcraft) is a pre-alpha Rust clone of the Pro Tools workflow. It has Duplicate and insert silence, but no Replace, room-tone fill, or stereo-to-mono split.
- SoundCraft is `MIT OR Apache-2.0`: oracle use is allowed, and code copy is allowed with the notices.

## Audacity

| Command | Menu and key | Result |
|---|---|---|
| Paste over a selection | Edit > Paste, Command-V | Replaces the selection. A shorter selection makes the track longer and moves the audio after it to the right. A longer selection makes the track shorter. |
| Paste, other cases | Edit > Paste | With "Editing clips can move other clips" off, the paste needs a gap. Stereo into a mono track gives an error. Mono into a stereo track goes into the two channels. |
| Duplicate | Edit > Duplicate, Command-D | Makes a new track. The new track holds only the selection, as a new clip, "at the same position on the Timeline". The copy does not go to the clipboard. |
| Split Stereo Track | Audio Track Dropdown Menu | Two tracks, one for each channel. The left track pans hard left and the right track pans hard right. |
| Split Stereo to Mono | Audio Track Dropdown Menu | Two "separately editable mono tracks". The two tracks pan center. |
| Make Stereo Track | Audio Track Dropdown Menu, on the upper of two mono tracks | The upper track becomes the left channel and the lower track becomes the right channel. The pan is 0. |
| Silence Audio | Edit > Remove Special > Silence Audio, Command-L | Replaces the selection with silence. This operation is destructive. Inference: the length stays the same, because the page says "replaces" and not "removes". |
| Generate > Silence | No default key | With a selection, the result is the same as Silence Audio. With no selection, it adds silence at the cursor (30 s default). |
| Truncate Silence | Effect > Special | Deletes the middle of each silent part, so the track gets shorter. It does not remove noise. |

The split commands make new tracks. They do not pick a channel inside a region.

No Audacity page names a room-tone or fill tool. Inference: a user pastes copied room tone over a selection, and the length changes.

## SoundCraft

- Repo: `storytold/soundcraft`. Its README calls it "a clean-room rebuild" of the Pro Tools workflow, in pure Rust, pre-alpha. The copyright holder is "ArtCraft Team and the SoundCraft contributors".
- Top-level files include `README.md`, `ROADMAP.md`, `NOTICE`, `LICENSE-MIT`, `LICENSE-APACHE`, and `Cargo.toml`.
- Relevant features in `README.md`:
  - The editing list has "duplicate", "insert silence", and "strip silence". The shortcuts list has "⌘D duplicate".
  - "separate (at selection, on grid, at transients)" splits a clip in time. It is not a channel split.
  - The README, `docs/parity-checklist.md`, and `docs/gaps.md` do not use "replace", "room tone", "fill", "mono", or "split" for an edit command.
- Inference: Duplicate follows Pro Tools, so the copy goes after the selection on the same track. No SoundCraft doc states this.

License:

- SPDX: `MIT OR Apache-2.0`. `LICENSE-MIT` is the standard MIT text. `LICENSE-APACHE` is the Apache 2.0 text with no appendix.
- Test oracle: allowed. Both licenses let anyone run the software for any purpose. A test that only compares outputs copies nothing.
- Code copy: allowed. Under MIT, keep the copyright and permission notice. Under Apache-2.0, keep the license and `NOTICE`, and mark the changed files. The ArtCraft marks are not licensed (`NOTICE`).
- Inference: SoundCraft is a weak oracle for this run. It can check only Duplicate and insert silence.

## Open questions

1. Does Audacity 4 change Duplicate or the split commands? The support pages for Audacity 4 did not load (404).
2. Does SoundCraft Duplicate put the copy after the selection, as Pro Tools does? Read the edit command in `crates/` to find out.

## Sources

- https://manual.audacityteam.org/man/edit_menu.html
- https://manual.audacityteam.org/man/edit_menu_copy_paste_and_duplicate.html
- https://manual.audacityteam.org/man/copy_and_paste_a_section_of_audio.html
- https://manual.audacityteam.org/man/edit_menu_remove_special.html
- https://manual.audacityteam.org/man/silence.html
- https://manual.audacityteam.org/man/truncate_silence.html
- https://manual.audacityteam.org/man/splitting_and_joining_stereo_tracks.html
- https://manual.audacityteam.org/man/audio_track_dropdown_menu.html
- https://manual.audacityteam.org/man/keyboard_shortcut_reference.html
- https://github.com/storytold/soundcraft
- https://raw.githubusercontent.com/storytold/soundcraft/main/README.md
- https://raw.githubusercontent.com/storytold/soundcraft/main/LICENSE-MIT
- https://raw.githubusercontent.com/storytold/soundcraft/main/LICENSE-APACHE
- https://raw.githubusercontent.com/storytold/soundcraft/main/NOTICE
- https://raw.githubusercontent.com/storytold/soundcraft/main/docs/parity-checklist.md
- https://raw.githubusercontent.com/storytold/soundcraft/main/docs/gaps.md
