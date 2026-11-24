# Contributing

The code is open to read, fork, and build under the Apache License 2.0. The project takes issues and pull requests only from collaborators.

The project takes no bug reports and no pull requests from other people. A person who got a DMG from the maintainer reports a bug to the maintainer: give the text of **Dirigible > About Dirigible** and the zip of **Help > Report a Problem...** (see [Report a problem](guide.md#report-a-problem)).

To report a security problem, use GitHub private vulnerability reporting, as [SECURITY.md](SECURITY.md) says. Never report it in an issue.

## How the project works

Agents and humans follow the same rules. [`AGENTS.md`](../AGENTS.md) has the commands, the testing rules, and the git rules. [`CODING_STANDARDS.md`](../CODING_STANDARDS.md) has the design rules and the **Safety** rules that a review checks. Every feature goes through the [`deliver` skill](../.claude/skills/deliver/SKILL.md): analyze, plan, review, implement test-first, review, verify, reflect, and land. Decision records are in [`docs/decisions/`](decisions/).

Run `make setup` once per clone. It enables the git hooks. A person who only builds the app does not need it.

## Make the screenshots again

The screenshots of the README and of the [user guide](guide.md) come from a script. The script makes the session "Demo Episode" with `say` voices, so the images show no personal data.

1. Give the terminal app the Screen Recording and Accessibility permissions.
2. Quit Dirigible. The script does not start while a copy of the app runs.
3. Run `scripts/screenshots.sh .scratchpads/screens`. The folder must be a new folder under `.scratchpads/`. The script builds the app first. A second argument, a language folder of `Support/Resources` such as `de`, makes the images in that language in `<folder>/images`; only the English run writes `docs/images`.
4. Do not move the pointer or other windows over the Dirigible window until the script stops.

The script writes `docs/images/screenshot-edit.png`, `docs/images/screenshot-zoom.png`, `docs/images/screenshot-inspector.png`, `docs/images/screenshot-episode.png`, `docs/images/screenshot-crossfade.png`, `docs/images/screenshot-settings.png`, and `docs/images/screenshot-silences.png`. No script makes six images: `docs/images/screenshot-duck.png`, `docs/images/screenshot-export-stems.png`, `docs/images/screenshot-reduce-noise.png`, `docs/images/screenshot-repair-sound.png`, `docs/images/screenshot-sync.png`, and `docs/images/screenshot-transcribe.png`. Make them by hand. The script also does not make `docs/images/screenshot-consent.png`, the sheet of an agent record request. Make it in the verify copy (`scripts/verify-copy.sh`): open a session with a Host track on the built-in microphone, send one `record` call of 30 seconds through `dirigible mcp`, and capture the window while the sheet shows. The Demo Episode has episode details, with the app icon as the artwork. It stops with an error when the window is not 1180 x 772 points, for example on a small screen, when the display scale is not 2x (Retina), and when the Settings window clips a text (`scripts/settings-fit.swift`). The images of the session window are 2360 x 1544 pixels.

## Make the banner again

The README banner has a light and a dark version. Make them again after a change of the app icon.

1. Run `make icon-preview`.
2. Run `swift scripts/banner.swift build/icon-preview docs/images`.

The script writes `docs/images/banner-light.png` and `docs/images/banner-dark.png` at 1600 x 400 pixels.

## Keep the user guide true

Each run that changes what a user sees or does updates the [user guide](guide.md). `make check-docs` fails when a `menu.*` name of `Support/Resources/en.lproj/Localizable.strings` or `es.lproj/Localizable.strings` is not in bold in the user guide. It also fails when a relative link of the user guide or of `README.md` names no file, or no heading of the .md file that it names.
