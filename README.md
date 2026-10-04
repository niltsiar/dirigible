<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/banner-dark.png">
  <img src="docs/images/banner-light.png" width="800" alt="Dirigible: podcast recorder and editor for macOS">
</picture>

Dirigible is a podcast recorder and editor for macOS. It records several microphones, audio interfaces, and other apps (for example a Zoom or Teams call) at the same time, each to its own track. You do not make an aggregate device in Audio MIDI Setup. Then you edit the tracks, add chapters, and export one file for your podcast host. Dirigible is modeled on Hindenburg PRO.

<img src="docs/images/screenshot-edit.png" width="800" alt="The Dirigible window with the Demo Episode session: the Host and Guest tracks, the marker Intro, the chapter Interview, a clip at -6 dB, and the loudness meter below the tracks.">

- macOS 14 Sonoma or later, on Apple silicon or Intel
- English and Spanish
- Apache License 2.0

## Features

- Record several input devices at the same time, one mono or stereo track for each input.
- Record the sound of another app, for example a call, on its own track (macOS 14.2 or later).
- Keep the recorded audio after a crash, an unplug, or a full disk.
- Edit with the keyboard or the mouse: cut, copy, paste, delete, split, nudge, move, and trim. Each edit is one undo step.
- Drag the gain line and the fade handles of a clip, press Command-F for a fade, or type the values in the inspector. Auto Level sets each clip to -16 LUFS (stereo) or -19 LUFS (mono), also after each take.
- Read the loudness of the mix in the meter below the tracks while you play.
- Play forward and backward with the J, K, and L keys, at slow and fast speeds.
- Find your way in a long session with the Session overview, zoom to the selection, and a zoom history.
- Add markers and chapters in the time ruler.
- Export WAV, AAC (.m4a), MP3, or FLAC, in mono or stereo, at 44.1 kHz or 48 kHz, at a loudness target such as -16 LUFS for a podcast, with the true peak at or under -1 dBTP.

Dirigible does not yet write chapters into the export or make crossfades in the window. Delete leaves silence. See [What Dirigible does not do yet](docs/guide.md#what-dirigible-does-not-do-yet).

## Install

### Build from source

You need Xcode 26 or later (Swift 6.2). You do not need an Apple developer account.

```sh
git clone https://github.com/niltsiar/dirigible.git
cd dirigible
```

```sh
make setup   # once per clone: enables the pre-commit hook
make run
```

`make run` builds `build/Dirigible.app` and opens it. Other commands:

| Command | What it does |
|---|---|
| `make app` | Builds `build/Dirigible.app`, universal and ad-hoc signed. |
| `make dmg` | Builds `build/Dirigible-<version>.dmg` and its `.sha256` file, ad-hoc signed and not notarized. |
| `make test` | Runs the tests. |
| `make check` | Runs the format check, the tests, and the checks on the built app. |
| `make format` | Formats the Swift code. |

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

## User guide

The [user guide](docs/guide.md) shows how to record, edit, and export an episode. It also lists each menu command with its key. In the app, choose **Help > Dirigible Guide**.

## The dirigible tool

`dirigible` is a command-line tool that makes, changes, and reads sessions. The DMG does not contain it. See [For contributors](docs/guide.md#for-contributors) in the guide.

## How the project works

Agents and humans follow the same rules. `AGENTS.md` has the commands, the architecture rules, the testing rules, and the git rules. Every feature goes through the `deliver` flow: analyze, plan, review, implement test-first, review, verify, land, and reflect. Decision records are in `docs/decisions/`.

## License

Apache License 2.0. See `LICENSE` and `NOTICE`.

The MP3 encoder is LAME 4.0 (`Sources/CLame`), under the GNU Library General Public License (LGPL), version 2 or later. The app holds its license text and notice in `Contents/Resources/LAME-COPYING.txt` and `LAME-NOTICE.txt`. `Sources/CLame/README.dirigible` lists the changed LAME files.
