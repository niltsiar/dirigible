# README and user guide for a macOS app

Date: 2026-09-27

This note prepares the README and guide run (backlog, user request 2026-09-26). The run adds a banner and a few screenshots to `README.md`, and it adds `docs/guide.md`, a short user guide. After that run, each user-facing run updates the guide. This note gives the conventions, the specifications, and a check that is realistic.

## Facts

### GitHub rendering

1. GitHub looks for a README in `.github/`, then in the repository root, then in `docs/`. It shows the first one that it finds. [1]
2. GitHub truncates the content of a README after 500 KiB. [1]
3. Use relative links for images and files in the repository. GitHub changes a relative link to the current branch, so the link works on each branch and in a clone. [1], [2]
4. GitHub makes a table of contents from the headings of each Markdown file (the outline menu). A README does not need its own table of contents. [1]
5. GitHub supports the HTML `<picture>` element. With `<source media="(prefers-color-scheme: dark)" srcset="...">` and a fallback `<img>`, GitHub shows a different image for the light theme and the dark theme. [2], [3], [4]

   ```html
   <picture>
     <source media="(prefers-color-scheme: dark)" srcset="docs/images/banner-dark.svg">
     <img alt="Dirigible" src="docs/images/banner-light.svg" width="800">
   </picture>
   ```

6. Git warns for a file over 50 MiB. GitHub refuses a file over 100 MiB. Git LFS is necessary only for a file over that limit. A GitHub repository is ideally smaller than 1 GB. [5] Screenshots of 0.2 MB to 1 MB do not need Git LFS.

### How other macOS apps write their README

The note read the README of seven open-source macOS apps on 2026-09-27 (`gh api repos/<repo>/readme`). [6]-[13]

| App | Top of the page | Screenshots | Install | Build from source |
|---|---|---|---|---|
| CotEditor [6] | Name, one paragraph, a bullet list (requirement, web site, languages) | One 2x PNG in the repository root (`screenshot@2x.png`, 1464 x 1302 px, 709 KB) | Link to the web site and the App Store | Yes, with a section "Build for ad-hoc usage" |
| Rectangle [7] | Name, one line, one image | One | Download, Homebrew | Short, at the end |
| Stats [8] | Centered icon, two images | Two, from a CDN | Manual, Homebrew, uninstall | No |
| Ice [9] | Centered icon, banner, a row of badges | A "Gallery" section at the end with five images | Manual, Homebrew | No |
| MonitorControl [10] | Icon at the left, download button, badges | One main screenshot, four small ones | Numbered steps "How to install and use the app" | Yes |
| IINA [11] | Centered icon | None in the README (a web site) | Link to the web site | Yes |
| AltTab [12] | One SVG banner that links to the web site | None | On the web site | No |

Patterns:

- Most apps show one strong image near the top, then a short text. The apps with a web site keep the README short.
- A long FAQ, many badges, and sponsor buttons are frequent, but they do not help a new user.
- AltTab uses an SVG file from the repository (`docs/readme/main.svg`) as its banner. [12]
- An app that is not notarized says so. AeroSpace puts a note near the top, and its Homebrew tap removes the quarantine attribute. [13]

### Gatekeeper for an app that is not notarized

7. On macOS 15 Sequoia and later, Control-click does not override Gatekeeper for software that is not notarized. The user goes to **System Settings > Privacy & Security** and clicks **Open Anyway**. [14], [15]
8. On macOS 14, Control-click, then **Open**, still works. [14] (The Apple news item says what changed in macOS 15. So the old method is valid on macOS 14.)
9. `xattr -dr com.apple.quarantine <app>` removes the quarantine attribute. Gatekeeper then does not check the app at launch. The current README already has these three methods, and they agree with [14] and [15].
10. Homebrew 5.0.0 deprecated casks without code signing. It "will disable all Homebrew/homebrew-cask casks that fail Gatekeeper checks in September 2026". It deprecated `--no-quarantine`. [16] So a Homebrew cask in the main tap is not an install path for Dirigible.

### Writing rules

11. Apple HIG, Writing: "Be clear. [...] If you can use fewer words, do so." Use a verb on a button. Use one capitalization style for each type of UI element. [17]
12. ASD-STE100 has different rules for procedures and for descriptions. A procedure uses the imperative and the active voice ("Install the component."). [18], [19] A user guide is mostly procedures, so STE fits it well. STE was made for readers with a basic knowledge of English. [19] This helps the Spanish-speaking users who read the English guide.

### Diátaxis

13. Diátaxis names four types of documentation: tutorials (learning), how-to guides (a task), reference (information), and explanation (understanding). Keep each type separate. [20]
14. A tutorial gives a result at each step, has almost no explanation, and must "work for every user, every time". [21]
15. A how-to guide assumes that the reader knows the basics. Its title says the result: "How to ...". "Practical usability is more helpful than completeness." [22]
16. Reference is "austere", mirrors the structure of the product, and uses the same pattern in each entry, for example a table. [23]

### Apple Help book

17. A help book is a folder of HTML pages with an index from `hiutil`. The app puts the `.help` bundle in `Contents/Resources/` and names it with the `CFBundleHelpBookFolder` and `CFBundleHelpBookName` keys of `Info.plist`. [24] `scripts/bundle.sh` could copy such a folder, so SwiftPM is not a blocker.
18. The Apple Help Programming Guide is in the documentation archive. Its last update is 2013-01-28. [24]
19. In SwiftUI, `CommandGroupPlacement.help` holds the Help menu commands. By default on macOS it has the "App Help" command. [25] A `CommandGroup(replacing: .help)` can open a URL in its place (unconfirmed for Dirigible: not tried).

### Screenshots with the scripts of this repository

20. `scripts/screenshot.sh` captures only the Dirigible window with `screencapture -x -o -l <window id>`. `-o` removes the window shadow, and `-x` stops the sound. [26] The script does not set or check the window size.
21. On this Mac (built-in Retina display, 2560 x 1600), a capture has 144 dpi, which is 2 pixels for each point. (Probe: `sips -g dpiWidth` on a 2x PNG gave 144.) So a window of 1200 x 750 points gives a PNG of 2400 x 1500 pixels.
22. `sips` changes the size and the format. It does not optimize a PNG. On the CotEditor PNG (709 KB, 1464 px wide), `sips --resampleWidth 1000` gave 528 KB, JPEG at quality 80 gave 228 KB, and HEIC gave 89 KB. (Probe in `.scratchpads/readme-probe/`.) JPEG blurs the edges of text. Browsers do not all show HEIC.
23. `-AppleLanguages "(en)"` at launch forces the English UI (docs/research/localization.md, fact 12). This makes screenshots in English on a Mac with a Spanish language setting.
24. `say -o host.wav --data-format=LEI16@48000 "..."` writes synthetic speech as a 48 kHz WAV file (probe: 1 channel, 48000 Hz, Int16). The `dirigible` command-line tool can make a session from such files (`create`, `track`, `file`, `clip`, `marker`). Synthetic speech gives a waveform that looks like a podcast and is not a real voice, so AGENTS.md permits it. (Unconfirmed: `dirigible file add` of a `say` WAV was not tried.)

### The UI names that a check can read

25. `Support/Resources/en.lproj/Localizable.strings` has 53 keys that start with `menu.`, with 52 different English names after the ellipsis is removed (for example `"menu.file.export" = "Export…";`). The Spanish file has the same keys. `L10n.swift` lists each key, and `MenuKeys.swift` has the shortcut of each menu item.

## Recommendations

### README outline

Keep the README short. It answers what the app does, how to get it, and where to read more. [1]

1. **Banner.** A `<picture>` with the light and the dark banner (fact 5). The `alt` text is "Dirigible".
2. **One paragraph and a short list**, as CotEditor does: what Dirigible does, then "Requirements: macOS 14 or later", "Languages: English, Spanish", "License: Apache 2.0". Replace the old "Status" paragraph with one line on what works today and a link to `docs/requirements/releases.md`.
3. **Main screenshot**: the session window during an edit.
4. **Features**: five to seven bullets, only features that work.
5. **Second screenshot**: recording with the input meters. Put it next to the recording bullets or under the features.
6. **Install**: the download link (when a release exists), then "Open a downloaded build" (the current text is correct, facts 7 to 9). Do not add a Homebrew cask (fact 10).
7. **User guide**: one line with a link to `docs/guide.md`.
8. **Build from source**: the current "Build and run" section, then "Keep the microphone permission across builds".
9. **How the project works**: the current short section (AGENTS.md, the deliver flow, decision records).
10. **License**.

Leave out: a badge row (there is no CI and no release count), sponsor buttons, a FAQ, a table of contents (fact 4), the full key table (it goes in the guide), animated GIFs (large files), and the architecture.

### Banner specification

- Content: the app icon at the left, the name "Dirigible", and one short line ("Podcast recorder and editor for macOS"). No screenshot in the banner.
- Size: an aspect ratio of 4:1, drawn at 1600 x 400 px, shown with `width="800"`.
- Format: SVG, with the text converted to paths, so the result does not depend on the fonts of the reader. Keep it under 100 KB. If the SVG uses filters that GitHub does not show correctly, export PNG at 1600 x 400 px.
- Light and dark: two files, `docs/images/banner-light.svg` and `docs/images/banner-dark.svg`, in a `<picture>` element (fact 5). The two files are different only in the text color and the background.
- Source: the vector source of the app icon (the icon run keeps it in the repository). The banner files are the source; no export step is necessary for SVG.

### Screenshot specification

- Count: two in the README (edit, record). A third (the export sheet) is optional and goes only in the guide.
- Names: `docs/images/screenshot-edit.png`, `docs/images/screenshot-record.png`, `docs/images/screenshot-export.png`. The guide uses the same files.
- Window: 1200 x 750 points, which gives 2400 x 1500 px at 2x (fact 21). Show each image with `width="800"`, so it is sharp on a Retina display.
- Format: PNG (text stays sharp, fact 22). Keep each file under 1 MB, and all README images under 3 MB. If a PNG is larger, make the window smaller. Do not add a PNG optimizer: that needs a decision record for a third-party tool.
- Appearance: light only. A window capture without a shadow is clear on the light theme and on the dark theme of GitHub. Two variants of each screenshot double the work at each UI change. The banner has light and dark variants because it is small and changes almost never.
- Language: English (`-AppleLanguages "(en)"`, fact 23).
- Content: a demo session with three tracks (host, guest, call), markers, and a chapter. Make it from synthetic speech (fact 24). Never use a recording of a real voice.

### How to regenerate the screenshots

Add a short procedure to the guide run, as a script or as steps in `docs/guide.md` under a "For contributors" note:

1. Make the demo session: `scripts/demo-session.sh <folder>` makes WAV files with `say`, then runs `dirigible create`, `track`, `file`, `clip`, and `marker`. The folder is under `.scratchpads/`.
2. Open the app in English: `open build/Dirigible.app --args -AppleLanguages "(en)"`, then open the demo session.
3. Set the window to 1200 x 750 points. Extend `scripts/screenshot.sh` so that it reads `kCGWindowBounds` and refuses a window of another size. (A resize through Accessibility needs a permission prompt. A size check does not.)
4. Run `scripts/screenshot.sh docs/images/screenshot-edit.png`, then put the app in the recording state and capture `screenshot-record.png`.
5. Check the file sizes with `ls -l docs/images`.

### Guide outline (`docs/guide.md`)

The guide follows Diátaxis (facts 13 to 16): one tutorial, then how-to sections, then reference tables. It has no explanation section; the decision records hold the explanations.

1. **Title and scope**: one sentence on what the guide covers and the version.
2. **Before you start**: install (link to the README), the permissions that macOS asks for (microphone, and the capture of other apps), and the menu language note (see below).
3. **Tutorial: Record your first episode**: make a session, add tracks, select an input for each track, record, stop, and find the files. Each step gives a visible result.
4. **How to record a call from another app** (Teams, Zoom).
5. **How to monitor the inputs**.
6. **How to edit**: set in and out points, select, cut, copy, paste, delete, split, nudge, and move and trim a clip with the mouse.
7. **How to add markers and chapters**.
8. **How to export**: the formats (WAV, AAC, FLAC) and Export Selection.
9. **How to recover after a crash or an unplug**: unplaced audio, **Retry Finalize**, and **Finish Without Unreadable Audio**.
10. **Reference: menu commands and keys**: one table with the columns Menu, Command, Spanish name, and Key. Sort it by menu, as the app shows it.
11. **Reference: files**: the session package, the `Clips/` folder, and a link to `dirigible --help` for scripts.

Write UI names in bold, as the app shows them, without the ellipsis (for example **Export**). Write a menu path with ">" (**File > Export**). The check below depends on the bold names.

### Language of the guide

Write the guide in English only, with one exception: the reference table has a column with the Spanish name of each menu command.

- AGENTS.md says that docs are in English. A full Spanish guide doubles the upkeep of each user-facing run, and no check can compare two prose texts.
- STE English is easy to read for a reader with a basic knowledge of English (fact 12).
- A user with a Spanish macOS sees Spanish menus. Without the Spanish column, that user cannot find **Export** when the menu says **Exportar…**. The Spanish column comes from `es.lproj/Localizable.strings`, and the check can compare it.
- Add a note at the top: "The guide uses the English names. The table in [Menu commands and keys] gives the Spanish names."

### Help menu

Do not make an Apple Help book now (facts 17 and 18). It needs HTML pages, a `hiutil` index, a change to `scripts/bundle.sh`, and a Spanish version. Consider later: replace the "Dirigible Help" command with a command that opens `docs/guide.md` on GitHub (fact 19). That needs a new L10n key in English and Spanish.

### A check that user-facing runs update the guide

Realistic: a check that each menu command has an entry in the guide. Not realistic: a check that the text or the screenshots are current.

Add this rule to `scripts/check-docs.sh`, and add a pass case and a fail case to `scripts/check-docs.test.sh`:

```bash
# Every menu command of the app has its English and Spanish name in bold in the user guide.
guide="$root/docs/guide.md"
if [[ -f "$guide" ]]; then
    for lang in en es; do
        strings="$root/Support/Resources/$lang.lproj/Localizable.strings"
        while IFS= read -r name; do
            grep -qF "**$name**" "$guide" || err "docs/guide.md: no **$name** ($lang menu name)"
        done < <(sed -nE 's/^"menu\.[^"]*" = "(.*)";$/\1/p' "$strings" | sed 's/…$//' | sort -u)
    done
fi
```

- It runs in `make check` through `make check-docs`. It costs a few milliseconds.
- The guide run adds `docs/guide.md` and the rule in the same commit. Until then, the `if` skips the rule.
- It fails when a run adds a menu command and does not add it to the guide. It also fails when a run renames a command and the guide keeps the old name.
- It does not see a toolbar button, a mouse action, a changed behavior, or an old screenshot. When the UI shell run adds toolbar keys (for example `toolbar.`), extend the `sed` pattern to those keys.
- Limit: `**Cut**` matches in any sentence, so the check proves a mention, not a correct description.

Add one rule to the deliver skill for the part that a script cannot see. In Phase 7 (verify): "If the run changes what a user sees or does, update `docs/guide.md`. If the window looks different, make the screenshots again (`docs/guide.md`, For contributors)." The code gate reviewers then check the guide diff with the code diff.

Do not add a check that compares the dates of `Sources/DirigibleApp/` and `docs/images/`. Each small UI fix would then fail `make check`, and the fix would be a new screenshot with no real change.

## Sources

1. GitHub Docs, "About the repository README file". https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-readmes
2. GitHub Docs, "Basic writing and formatting syntax" (relative links, images, `<picture>`). https://docs.github.com/en/get-started/writing-on-github/getting-started-with-writing-and-formatting-on-github/basic-writing-and-formatting-syntax
3. GitHub Changelog, "Specify theme context for images in Markdown (Beta)" (2022-05-19). https://github.blog/changelog/2022-05-19-specify-theme-context-for-images-in-markdown-beta/
4. GitHub Blog, "How to make your images in Markdown on GitHub adjust for dark mode and light mode" (2025-04-18). https://github.blog/developer-skills/github/how-to-make-your-images-in-markdown-on-github-adjust-for-dark-mode-and-light-mode/
5. GitHub Docs, "About large files on GitHub". https://docs.github.com/en/repositories/working-with-files/managing-large-files/about-large-files-on-github
6. CotEditor README. https://github.com/coteditor/CotEditor ; screenshot: https://raw.githubusercontent.com/coteditor/CotEditor/main/screenshot@2x.png
7. Rectangle README. https://github.com/rxhanson/Rectangle
8. Stats README. https://github.com/exelban/stats
9. Ice README. https://github.com/jordanbaird/Ice
10. MonitorControl README. https://github.com/MonitorControl/MonitorControl
11. IINA README. https://github.com/iina/iina
12. AltTab README. https://github.com/lwouis/alt-tab-macos
13. AeroSpace README (note on notarization and quarantine). https://github.com/nikitabobko/AeroSpace
14. Apple Developer News, "Updates to runtime protection in macOS Sequoia" (2024-08-06). https://developer.apple.com/news/?id=saqachfa
15. Apple Support, "Safely open apps on your Mac". https://support.apple.com/en-us/102445
16. Homebrew, "Homebrew 5.0.0" (2025-11-12). https://brew.sh/2025/11/12/homebrew-5.0.0/
17. Apple Human Interface Guidelines, "Writing". https://developer.apple.com/design/human-interface-guidelines/writing
18. ASD-STE100, "About STE". https://www.asd-ste100.org/about_STE.html
19. ASD-STE100, "FAQ". https://www.asd-ste100.org/STE_faq.html
20. Diátaxis, home page. https://diataxis.fr/
21. Diátaxis, "Tutorials". https://diataxis.fr/tutorials/
22. Diátaxis, "How-to guides". https://diataxis.fr/how-to-guides/
23. Diátaxis, "Reference". https://diataxis.fr/reference/
24. Apple, Apple Help Programming Guide, "Registering Your Help Book" (documentation archive, 2013-01-28). https://developer.apple.com/library/archive/documentation/Carbon/Conceptual/ProvidingUserAssitAppleHelp/registering_help/registering_help.html
25. Apple, SwiftUI `CommandGroupPlacement.help`. https://developer.apple.com/documentation/swiftui/commandgroupplacement/help
26. SS64, `screencapture` man page. https://ss64.com/mac/screencapture.html
