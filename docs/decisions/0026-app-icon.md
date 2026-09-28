# 0026. App icon: one Icon Composer source compiled by actool at target 14.0, concept W1 "waveform window"

- Status: accepted
- Date: 2026-09-29
- Accepted: 2026-09-28, the user approved the final W1 art (row 2026-09-28T22:29 of `.scratchpads/runs/2026-09-28-app-icon/decisions.tsv`). Plan gate 1 of the app-icon run closed the build design.
- Amends: 0001 (Build).

## Context

Release 2 run 3 (`docs/requirements/releases.md`) adds the app icon (R1 part). The user asked for an icon that contains a dirigible and an old-fashioned metal microphone. The app runs on macOS 14 and later (deployment target 14.0). On macOS 26, the system draws app icons with Liquid Glass layers and has light, dark, tinted, and clear looks. The build has no Xcode project (0001). Research: `docs/research/app-icon.md`.

Probes on 2026-09-28 (macOS 15.7.9, Xcode 26.3, `actool` 26.3; `.scratchpads/runs/2026-09-28-app-icon/probe-actool/`):

- P1. A `.icon` folder with SVG layers compiles with `xcrun actool` at `--minimum-deployment-target 14.0` into `Assets.car` (renditions 16 to 1024 px for `NSAppearanceNameAqua`, `NSAppearanceNameDarkAqua`, and `ISAppearanceTintable`) and `AppIcon.icns` (16 to 256 px).
- P6. At target 26.0, `actool` writes the same renditions. `assetutil --info` shows `"PlatformVersion" : "26.0"` in place of `"14.0"`.
- P7. With a relative path to the `.icon`, `actool` printed an error, wrote no file, and exited 0.

## Decision

**Format.** The only source of the icon is the Icon Composer folder `Support/AppIcon.icon` (`icon.json` and SVG layers), in git. `scripts/icon.sh` compiles it with `xcrun actool` into `Assets.car` and `AppIcon.icns`, with the asset name `AppIcon`, at `--minimum-deployment-target 14.0`. It passes the absolute path of the `.icon`, compiles into a temporary folder, and fails when `actool` prints an error or a file is missing (P7). Only then does it replace `build/icon`. `scripts/bundle.sh` copies the two files to `Contents/Resources/`. `Support/Info.plist` names the asset: `CFBundleIconName` and `CFBundleIconFile` are `AppIcon`. The build does not merge the partial Info.plist of `actool`.

**Concept.** W1 "waveform window": an airship with a window cut through its envelope, and a waveform in the window, over a navy background with a dark variant. `Support/AppIcon.icon` is the only source of the shapes and the colors. This record does not copy them. The tinted look has its own fill for the waveform bars (white).

**Preview.** `make icon-preview` writes the flat renditions and the macOS 26 looks to `build/icon-preview/` with `iconutil` and `ictool` (a tool inside Icon Composer, which comes with Xcode 26). The bundle build does not need `ictool`.

## Consequences

- The build needs Xcode 26 for `actool`. The repo already needs it (0001). A Mac with only the Command Line Tools fails with a clear message.
- The `icon.json` schema is not documented. Keep only the keys that the probes proved. After an edit in Icon Composer, commit the `icon.json` that it writes.
- macOS 14 and 15 show the flat renditions. macOS 26 shows the layers with Liquid Glass. The run could not see the icon on a macOS 26 Mac; that is a manual check.
- A change of the art changes only `Support/AppIcon.icon`, and needs a new user approval.
- `AppBundleTests` checks the bundle: both Info.plist keys, both files, the asset that the plist names at 1024 px, the three appearances, and the target 14.0.

## Alternatives considered

- **A PNG iconset compiled by `iconutil` into `AppIcon.icns` only.** Rejected: an icns-only icon has no dark, clear, or tinted look, and macOS 26 can put it in a gray tile (research section 1).
- **An asset catalog (`.xcassets`) with PNG files per size.** Rejected: one PNG file per size in git (ten files), and no Liquid Glass layers (research section 2).
- **Other concepts.** The run made three rounds of concepts (a ribbon-mic airship, a mic gondola with six microphone variants, and waveform and pixel-art directions). The user chose W1. W3 "waveform contrail" was the close alternative. The sources stay in the run folder.
