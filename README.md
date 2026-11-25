<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/banner-dark.png">
  <img src="docs/images/banner-light.png" width="800" alt="Dirigible: podcast recorder and editor for macOS">
</picture>

Dirigible is a podcast recorder and editor for macOS. It records several microphones, audio interfaces, and other apps (for example a Zoom or Teams call) at the same time, each to its own track. You do not make an aggregate device in Audio MIDI Setup. Then you edit the tracks, add chapters, and export one file for your podcast host. Dirigible is modeled on Hindenburg PRO.

<img src="docs/images/screenshot-edit.png" width="800" alt="The Dirigible window with the Demo Episode session: the Host and Guest tracks, the marker Intro, the chapter Interview, a clip at -6 dB, and the loudness meter below the tracks.">

- macOS 14 Sonoma or later, on Apple silicon or Intel
- English, Spanish, German, French, Italian, Dutch, Brazilian Portuguese, and European Portuguese (Dirigible > Settings)
- Apache License 2.0

## Features

- Record several input devices at the same time, one mono or stereo track for each input.
- Record the sound of another app, for example a call, on its own track (macOS 14.2 or later). Safari, Safari Technology Preview, and FaceTime cannot be a source: see the [limit of app sound](docs/guide.md#limits).
- Start a take at the playhead after a short play of the session with **Record > Record with Pre-roll** (P).
- Hear a microphone in your headphones while you record: click the headphones button in the track header, or choose **Track > Monitor Track** (Control-Command-M).
- Keep the recorded audio after a crash, an unplug, or a full disk. A banner warns when less than 3 hours of record time is left.
- Save a zip of the logs and crash reports of Dirigible with **Help > Report a Problem...**. The zip has no audio, and Dirigible sends nothing.
- Go back to an earlier state of the session with **File > Revert To**. Dirigible keeps backups of the session, and Undo reverses a revert.
- Make a session smaller after many retakes with **File > Remove Unused Files...**. It shows the list and the size first, and moves the files to the Trash.
- Save disk space on a finished session with **File > Archive Session...**. Dirigible converts the clip files to FLAC with the same samples, usually to half the size. An edit, Play, or an export converts them back first, and **File > Unarchive Session** does it alone.
- Import WAV, AIFF, FLAC, MP3, and M4A files into a track, by the menu or a drag from Finder, also on an empty session. Dirigible copies each file into the session at the session sample rate and levels it.
- Merge the session of another Dirigible into the open session with **File > Import Session...**, for example two recordings of one conversation. Each track of the other session comes as a new track, with its gain, mute, and clips, and Undo reverses it.
- Save a session as a template with **File > Save as Template...**, then start each new episode from it in the start window.
- Edit with the keyboard or the mouse: cut, copy, paste, delete, split, nudge, move, and trim. Ripple delete, insert, and ripple trim keep all tracks and the markers in sync. Command-click clips on several tracks and drag them together. Clips snap to the edges of other clips, to the playhead, and to markers (**View > Snap**, N). **Edit > Drag Mode** sets what a drag does to the clips under it. **Edit > Close Gaps** moves selected clips together, and **Edit > Heal Clips** joins the parts of a split clip. Each edit is one undo step.
- Keep a part of the session in a bin (**View > Show Bins**, Option-Command-C) and paste it again, for example a jingle. **Edit > Add to Favorites** keeps a sound for all sessions.
- Import a Whisper JSON, WebVTT, or SRT transcript with **File > Import Transcript...**, the dirigible tool, or an AI agent, find a phrase, and cut its words from all tracks in one edit. A transcript of one take, made before any edit, lands on the edited audio. Export the transcript as SRT or WebVTT subtitles that match the edited episode. In the app, File > Export Transcript writes the same SRT or WebVTT file. Transport > Go to Take Time (Command-J) goes to a time of the recording. A banner shows when an agent edit breaks the sync of a take, with Undo.
- Write the words of a track with Tools > Transcribe Track. It runs whisper.cpp on your Mac, so the audio stays there. The only network call is the one-time download of the model (148 MB, 190.1 MB, or 574 MB). You can also choose a whisper model file of your own, which Dirigible checks before it uses it. The words land in the Transcript tab of the inspector, and `dirigible transcribe` does the same job in Terminal.
- Let an AI agent do common jobs in few calls: one `import` places a sound with its range, gain, and fades; `chapters_import` reads a chapters file and `chapters_export` writes a text chapter list; `clip_heal` joins the pieces of a split clip; `session_info` with `compact` reads a long session in fewer tokens.
- Drag the gain line and the fade handles of a clip, press Command-F for a fade or for a crossfade where two clips touch, or type the values in the inspector. Auto Level sets each clip to -16 LUFS (stereo) or -19 LUFS (mono), also after each take. Level Over Time evens out the level of speech inside a clip with a gain layer that Remove Level Over Time takes away.
- Give each track a role (dialogue, music, or effects), then lower the music under the speech with Tools > Duck Music Under Speech, in one undo step.
- Find the long silences with Tools > Find Silences, then shorten, mute, or mark each one from a list, in one undo step. An AI agent does the same with `silence_edit`.
- Move a clip that you recorded on another device to the place where its audio matches a track, with Tools > Sync Clip to Track (Option-Command-G), in one undo step. An AI agent does the same with `clip_sync`.
- Replace a selected range with the copy (Edit > Replace, Shift-Command-V), or fill it with the copy again and again, for example with room tone (Edit > Paste to Fill Selection, Option-Command-V).
- Split a stereo clip into two mono tracks with Tools > Split Stereo to Mono (Shift-Command-D), then cut, level, and mute each voice alone.
- Take background noise or mains hum out of a clip with Tools > Reduce Noise, and listen to a preview first. It makes a new file for the clip, and Tools > Restore Original Audio (Shift-Command-O) puts the old file back at any time.
- Move the sound of a track toward a reference voice with Track > Match Voice. Choose a clip with Use as Voice Reference, then Match Voice to that clip. The match is a live EQ curve with an Amount slider, Bypass, and Remove, and no audio file changes.
- Repair a clip with Tools > Repair Sound: repair clipped peaks, reduce rumble, and soften harsh "s" sounds, with a preview first. A repair of clipped peaks makes the clip quieter, and a banner says by how much.
- Read the loudness of the mix in the meter below the tracks while you play.
- Play forward and backward with the J, K, and L keys, at slow and fast speeds.
- Play faster or slower with the voices at their pitch, from 0.75x to 2x.
- Find your way in a long session with the Session overview, zoom to the selection, and a zoom history.
- Make quiet sound taller in the waveforms with View > Waveform Zoom In (Option-Command-Up Arrow), over a range of 24 to 145 dB. A dB scale beside each track shows the range.
- Find a clip, a marker, or a chapter in the session index (View > Show Session Index, Shift-Command-2): it lists them in time order, filters them by kind, searches their names, and plays from a row with a double click.
- Add markers and chapters in the time ruler, or during a take with Command-Return and Shift-Command-Return to mark a mistake. Give each chapter a link and an image in the inspector (Markers > Marker Info). The MP3 and M4A exports contain the chapters, and File > Export Chapters writes a chapters.json file for your podcast host.
- Export WAV, AAC (.m4a), MP3, or FLAC, in mono or stereo, at the session rate, 44.1 kHz, or 48 kHz, at a loudness target such as -16 LUFS for a podcast, with the true peak at or under -1 dBTP. **File > Export Stems...** writes one file for each track or role, and **File > Export with Presets...** writes several formats in one run. An export can also write one file for each chapter or marker.
- Add the episode details and the artwork in the inspector (File > Episode Info). The MP3 and M4A exports contain them.

## Install

### Build from source

You need Xcode 26 or later (Swift 6.2). You do not need an Apple developer account.

```sh
git clone https://github.com/niltsiar/dirigible.git
cd dirigible
```

```sh
make run
```

`make run` builds `build/Dirigible.app` and opens it. Other commands:

| Command | What it does |
|---|---|
| `make app` | Builds `build/Dirigible.app`, universal and ad-hoc signed. |
| `make dmg` | Builds `build/Dirigible-<version>.dmg` and its `.sha256` file, ad-hoc signed and not notarized. |
| `DIRIGIBLE_FULL_SUITE=1 make test` | Runs the tests. A bare `make test` refuses to run. |
| `DIRIGIBLE_FULL_SUITE=1 make check` | Runs the format check, the docs check, the warning check, the size check, the tests, the hook tests, and the checks on the built app. A bare `make check` refuses to run. |
| `make format` | Formats the Swift code. |

To change the code, run `make setup` once per clone. [Contributing](docs/CONTRIBUTING.md) says why, and [AGENTS.md](AGENTS.md) has the rules of the build lock.

#### Keep the microphone permission across builds

macOS links the microphone permission to the code signature of the app. The default ad-hoc signature changes on every build, so macOS can ask for the permission again after a rebuild. To stop this, sign with a local certificate:

1. Open Keychain Access. Select **Keychain Access > Certificate Assistant > Create a Certificate**.
2. Enter the name `Dirigible Local`, set **Certificate Type** to **Code Signing**, and click **Create**.
3. Build with the certificate:

   ```sh
   SIGN_IDENTITY="Dirigible Local" make run
   ```

### Install from a DMG

Use a DMG that `make dmg` built, or a DMG that the maintainer of the project gave you. Do not open a Dirigible DMG from another source.

1. Open the DMG.
2. Drag **Dirigible** to **Applications**.
3. Open Dirigible from the Applications folder.

Each DMG has a new ad-hoc signature. So after each update, macOS asks again for access to System Audio Recording, and it can ask again for access to the microphone. After each update, before you record a show, open the call app, turn on **Input Levels** with its track armed, and click **Allow** when macOS asks. Then make a short test take with each microphone and the call app. The guide tells what to do when an app track records no sound ([Record a call or another app](docs/guide.md#record-a-call-or-another-app)).

If you got the DMG from the maintainer and find a bug, report it to the maintainer. Give the text of **Dirigible > About Dirigible**: the version and, in parentheses, the commit of the build. Attach the zip of **Help > Report a Problem...** (see [Report a problem](docs/guide.md#report-a-problem)). `dirigible --version` prints the same version as the About text. A release version is `0.<release>.<run>`, for example `0.3.4`. A fix after a run has a fourth number: `0.<release>.<run>.<fix>`, for example `0.3.4.1`. A build after the last release tag adds `-<commits>-g<commit>`, and a build with uncommitted changes adds `-dirty`. The rule is in [Versions](docs/requirements/releases.md#versions).

No native speaker has checked the German, French, Italian, Dutch, and Portuguese (Brazil and Portugal) texts yet. To report a wrong text to the maintainer, give the language, the window, the wrong text, and the text that you expect.

`make dmg` also writes `Dirigible-<version>.dmg.sha256`. To check a DMG against this file, put both files in one folder and run `shasum -a 256 -c Dirigible-<version>.dmg.sha256` there. The result must be `OK`.

### Open Dirigible for the first time

A DMG that you build on your Mac opens with no warning. A DMG that you get from another person shows a warning at the first open. The warning shows because Apple did not check the app. The project has no paid Apple developer account, so the app is not notarized. The warning does not mean that the app is damaged.

On macOS 15 and later:

1. In the warning, click **Done**. Do not click **Move to Trash** (**Move to Bin** in British and Australian English).
2. Open **System Settings > Privacy & Security**.
3. Scroll down to **Security** and click **Open Anyway**.
4. Enter your password when macOS asks for it.
5. When the warning shows again, click **Open**.

On macOS 14:

1. In the Applications folder, Control-click **Dirigible** and choose **Open**.
2. In the warning, click **Open**.

If macOS says that "Dirigible" is damaged and cannot be opened, and you use Terminal, run this command, then open the app again:

```sh
xattr -dr com.apple.quarantine /Applications/Dirigible.app
```

This command also lets the dirigible tool run. If Dirigible is not in the Applications folder, use its path in place of `/Applications/Dirigible.app`.

## User guide

The [user guide](docs/guide.md) shows how to record, edit, and export an episode. It also lists each menu command with its key. In the app, choose **Help > Dirigible Guide**. Before a show, do the steps in [Before you record a show](docs/guide.md#before-you-record-a-show).

## The dirigible tool

`dirigible` is a command-line tool that makes, changes, and reads sessions. The app contains it. [The dirigible tool](docs/guide.md#the-dirigible-tool) in the guide shows how to type `dirigible` in Terminal, with and without administrator rights. Open the app once before you run the tool: see [Open Dirigible for the first time](#open-dirigible-for-the-first-time).

An AI agent (Claude Code, Codex, opencode, or any MCP app) can read and edit a session through `dirigible mcp`. A take that an agent starts with its `record` tool starts only when you click Record in a sheet of the app, or while a window grant that you gave lasts. An agent with a shell can run `dirigible record`, which records at once with no sheet: see [Make your agent ask first](docs/guide.md#make-your-agent-ask-first). [Connect an AI agent](docs/guide.md#connect-an-ai-agent) shows the setup, and [What you can ask an agent](docs/guide.md#what-you-can-ask-an-agent) gives example requests, the recipes, and the agent skill.

## Documentation

- [User guide](docs/guide.md): how to record, edit, and export an episode, and the list of menu commands.
- [Contributing](docs/CONTRIBUTING.md): who can open issues and pull requests, and how the project works.
- [Security](docs/SECURITY.md): how to report a security problem.
- [How Dirigible was made](docs/provenance.md): the statement of how the code was made, and the third-party parts.
- [Docs map](docs/README.md): the requirements, the decisions, the research, the glossary, and the workflow docs.

## Contributing

The project takes issues and pull requests only from collaborators. [Contributing](docs/CONTRIBUTING.md) tells how the project works.

## How Dirigible was made

We wrote the code of Dirigible for this project. The exceptions are the third-party parts in the table of docs/provenance.md, each with its license and notice. [How Dirigible was made](docs/provenance.md) holds the full statement.

## License

Apache License 2.0. See [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE). The [table of third-party parts](docs/provenance.md#third-party-parts) names the license and the notice file of each part.
