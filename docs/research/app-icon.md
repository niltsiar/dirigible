# App icon for Dirigible

Date: 2026-09-27

This note answers how to make and ship the app icon of Dirigible. The user wants "a really nice app icon", with a dirigible and an old-fashioned metal microphone. The app runs on macOS 14 and later. `scripts/bundle.sh` builds the bundle with SwiftPM, not with an Xcode project.

Probe host: macOS 15.7.9, Xcode 26.3 (build 17C529), `actool` 26.3, Icon Composer 1.2. The probes did not run on macOS 26 or 27. Results for those versions come from the sources and are marked "(unconfirmed)" where no Apple source states them.

## Recommendation in short

Keep an Icon Composer file `Support/AppIcon.icon` in git, with SVG layers. `scripts/icon.sh` compiles it with `xcrun actool` into `Assets.car` and `AppIcon.icns` (state on 2026-11-24; the plan of 2026-09-27 put the compile in `scripts/bundle.sh`, which copies the two files). `Support/Info.plist` names both. One source gives the Liquid Glass icon on macOS 26 and later, and a flat icon on macOS 14 and 15. There is no new dependency.

## 1. Icon shape and grid

### macOS 11 to 15

- The canvas is 1024 x 1024 px. The body is a rounded rectangle of 824 x 824 px, centered, with a margin of 100 px on each side [9], [10].
- Probe: the flat 1024 px image that `actool` makes from a `.icon` file has its opaque pixels in x 100...923 and y 100...923, so the body is 824 x 824 px. The 16 px image has a 14 x 14 px body. (Probe `svg-layer`, `icon-format`.)
- In macOS 11 to 15, the rounded rectangle is a design element, not a mask. An icon can have transparency, a drop shadow, and parts that go past the edge [10].

### macOS 26 and later (Liquid Glass)

- The layout is a 1024 x 1024 px square. The system masks it to a rounded rectangle. The style is "layered": one background and one or more foreground layers [1].
- The system adds specular highlights, refraction, translucency, and shadows. Do not draw these effects in the art [1].
- There are six appearances: default, dark, clear light, clear dark, tinted light, and tinted dark. The system makes the appearances that you do not supply [1].
- "The canvas shape now acts as a mask to designs." An old icon with a rounded-rectangle shape gets masked or extended to fit. For an icon with a unique shape, "the system removes any drop shadows and then auto-scales the artwork into our rounded rectangle canvas" [3].
- Users call this auto-scaled result "squircle jail": the old art is smaller and sits on a gray rounded rectangle [11], [12], [13]. A developer report says that an icon with transparent edges from a legacy `.icns` got a gray tile in the Dock, and that a compiled `.icon` in `Assets.car` gave one tile [14].
- An app with only a legacy `.icns` does not get the clear and tinted styles [15].
- Apple: "In iOS, iPadOS, macOS, and watchOS versions earlier than 27, specular highlights appear on when you choose Inside or Outside, and Refraction settings have no visible effect" [2]. Thus macOS 27 renders the same `.icon` file with more effects.

### What a macOS 14 app ships

Ship `Assets.car` from a `.icon` file and the `AppIcon.icns` that `actool` makes next to it. Set both `CFBundleIconName` and `CFBundleIconFile`.

- macOS 26 and later read `CFBundleIconName` and use the layered icon in `Assets.car` [2], [14], [16].
- For an earlier deployment target, "Xcode automatically generates app icon images at build time for those releases from the Icon Composer file" [2]. Probe: `actool` with `--minimum-deployment-target 14.0` put flat renditions of 16 to 1024 px in `Assets.car` and wrote `AppIcon.icns`.
- The flat renditions already have the rounded rectangle, a glass edge, and a shadow. They look correct on macOS 14 and 15. (Probe; visual check of `svg-layer/car.iconset/icon_512x512@2x.png`.)
- Apple does not support a second, different icon for macOS 15 and earlier. Xcode 26 shows the `.icon` art on all versions, and Apple said this is "by design" [8].
- A legacy `.icns` only is the weaker choice. It has no dark, clear, or tinted styles, and it can go into the gray tile on macOS 26.

## 2. Sizes, iconutil, and actool

### iconset and icns

- An `.iconset` folder has ten PNG files: `icon_16x16.png`, `icon_16x16@2x.png`, `icon_32x32.png`, `icon_32x32@2x.png`, `icon_128x128.png`, `icon_128x128@2x.png`, `icon_256x256.png`, `icon_256x256@2x.png`, `icon_512x512.png`, `icon_512x512@2x.png`. The pixel sizes are 16, 32, 32, 64, 128, 256, 256, 512, 512, and 1024. (Probe `compile`: `iconutil -c iconset` wrote these names back from an `.icns`.)
- `iconutil -c icns <x>.iconset -o <x>.icns` makes an `.icns`. `iconutil -c iconset <x>.icns` does the reverse. `iconutil` "may extract icons from '.car' asset catalogs": `iconutil -c iconset Assets.car AppIcon` [6]. (Probe `compile`, `icon-format`: all three work.)
- `iconutil` is in `/usr/bin` on a stock Mac. `actool` needs Xcode, not only the Command Line Tools [17].

### actool without an Xcode project

`actool` compiles an `.xcassets` folder or an Icon Composer `.icon` file with no Xcode project [16], [17]. Probe `icon-format` and `svg-layer` used this command:

```sh
xcrun actool Support/AppIcon.icon --compile "$out" \
  --app-icon AppIcon --platform macosx --target-device mac \
  --minimum-deployment-target 14.0 --include-all-app-icons \
  --output-partial-info-plist "$out/partial.plist" \
  --output-format human-readable-text --errors --warnings
```

Results:

| Input | Output | Partial Info.plist |
|---|---|---|
| `Assets.xcassets` with a 10-PNG `AppIcon.appiconset`, target 14.0 | `Assets.car` (231 KB), `AppIcon.icns` | `CFBundleIconFile = AppIcon`, `CFBundleIconName = AppIcon` |
| `AppIcon.icon` with a PNG layer, target 14.0 | `Assets.car` (1.8 MB), `AppIcon.icns` | same |
| `AppIcon.icon` with a PNG layer, target 26.0 | same files | same |
| `AppIcon.icon` with an SVG layer, target 14.0 | `Assets.car` (1.7 MB), `AppIcon.icns` | same |

- `assetutil --info` on the `.icon` output shows renditions for `NSAppearanceNameAqua`, `NSAppearanceNameDarkAqua`, and `ISAppearanceTintable`, plus flat PNG renditions of 16 to 1024 px for `macosx` 14.0.
- The `--app-icon` name must be the file name of the `.icon` file without the extension [2].
- A `.icon` file has at most four groups, or it does not compile [4], [17].
- The `.icns` from a `.icon` file had only 16, 32, 128, and 256 px images. The 512 and 1024 px images are in `Assets.car`. (Probe `icon-format`.)
- A `.icon` file does not need macOS 26 to compile or to render a preview. Xcode 26.3 on macOS 15.7.9 did both. Only the layered, live display needs macOS 26 at run time. Icon Composer 1.2 needs macOS 15.3 (`LSMinimumSystemVersion` in its Info.plist).
- Probe trap: inside `scripts/probe.sh`, `actool` could not write `Assets.car` into the repo or into `/private/tmp` ("Operation not permitted"). It could write into `mktemp -d` (under `/private/var/folders`). The probes compiled there and copied the result. `qlmanage` did not start in the sandbox ("sandbox initialization failed"). A build outside the probe sandbox has no such limit (unconfirmed).

### ictool previews

`ictool` is in `Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/`. It renders a `.icon` file to a PNG for one appearance [18], [19]:

```sh
"$ICTOOL" Support/AppIcon.icon --export-preview macOS Dark 512 512 1 dark.png
```

Probe `ictool`: `Light`, `Dark`, `TintedLight`, and `ClearLight` gave 512 px images. These previews fill the whole canvas with no 100 px margin [19]. Use them to compare appearances, not as the shipped art.

## 3. Vector source and rasterization

- A `.icon` file is a folder: `icon.json` and `Assets/` with the layer images. Layers can be SVG or PNG. Apple prefers SVG: "use vector graphics to draw shapes and export SVG files". Convert text to outlines. Do not export the canvas mask [2], [4].
- Thus the vector source in git is the `.icon` folder itself: SVG layers plus `icon.json`. All are text files that a diff shows. `actool` rasterizes every size, so the repo needs no separate rasterization step.
- Apple does not document the `icon.json` schema. The probes used only these keys: `fill.automatic-gradient`, `groups[].layers[].image-name`, `groups[].layers[].name`, `groups[].shadow`, `groups[].translucency`, `supported-platforms.squares`. Tune other effects in Icon Composer and commit the `icon.json` that it writes.
- If a pipeline needs PNG files from an SVG without `actool` (the legacy `.iconset` path), a short Swift script works with no new dependency. `NSImage(contentsOf:)` reads an SVG file as `_NSSVGImageRep` on macOS 15, and `NSBitmapImageRep` draws it at any size. Probe `svg`: the script rendered a gradient SVG to 1024 px and 16 px PNG files with alpha. The probe did not test macOS 14 for this.
- `sips` does not read SVG. `rsvg-convert` is a Homebrew dependency. `qlmanage -t` did not run in the probe sandbox.

## 4. Design guidance and concepts

### Rules from Apple

- "Embrace simplicity." Find one core idea and express it "with a minimal number of shapes" [1].
- Prefer a simple background: a solid color or a gradient [1].
- Use filled, overlapping shapes with clearly defined edges. Vary opacity in foreground layers for depth [1].
- No text, no photos, no copy of UI parts [1].
- No baked-in highlights, drop shadows, bevels, blurs, or glows. The system adds these [1], [3].
- Prefer a front or side view. Avoid complex 3D perspective that competes with the material [3].
- Keep the features the same in all appearances. Make the dark icon from the light one [1].
- Put each color in its own layer, so a dark variant is one fill change [4].
- Keep the source "flat, opaque, and easy to control" [4].

### Small sizes

- At 16 px, the body is 14 x 14 px (probe). Only the silhouette and one or two color masses stay visible.
- One `.icon` file gives all sizes. There is no separate art for 16 px. The silhouette must work alone: a horizontal ellipse (the envelope) against a contrasting sky.
- Grille ribs, rivets, and cables disappear under 64 px. Use at most five ribs, each at least 24 px wide at 1024 px.
- Avoid the Hindenburg disaster in the imagery: no fire, no smoke, no swastika-era tail marks. The name only alludes to the airship.

### Concept A: "Ribbon Zeppelin" (preferred)

State on 2026-11-24: the shipped icon is W1 "waveform window" (decision 0026), not Concept A. The text below is the preference of 2026-09-27.

The envelope of the airship is the chrome body of a 1930s ribbon microphone, seen from the side. The envelope is a silver pill with four or five vertical grille ribs, the classic look of a ribbon mic grille. Under it, a small gondola is shaped like the yoke of the mic mount. Four tail fins, in a darker metal, finish the airship. The airship rises at about 8 degrees to the right. The background is a dusk gradient from deep blue at the top to warm amber at the bottom. Layers: background fill; group 1, the envelope; group 2, the ribs; group 3, the gondola and the fins. At 16 px it reads as a silver pill on blue.

### Concept B: "Mooring mast"

A vintage broadcast microphone on a tall stand is the mooring mast. A small silver airship is moored at its tip, nose to the mic. The mic head is a round chrome capsule with a grille, in front view. The stand runs down to the bottom edge. The background is a pale sky gradient. This concept tells a story (airships moored at masts), but at 16 px it becomes a pill and a thin line.

### Concept C: "Airship on the air"

A side view of a silver airship with a mesh envelope, like the grille of a 1950s dynamic mic. Two or three concentric sound-wave arcs come from the nose, in a translucent layer. The Liquid Glass refraction makes the arcs shine. At 16 px the arcs disappear, and the airship alone remains.

## 5. Test and preview

### Test in AppBundleTests

`Tests/DirigibleTests/AppBundleTests.swift` checks the built bundle through `DIRIGIBLE_APP`. Add one test:

1. `Contents/Info.plist` has `CFBundleIconName == "AppIcon"` and `CFBundleIconFile == "AppIcon"`.
2. `Contents/Resources/Assets.car` and `Contents/Resources/AppIcon.icns` exist.
3. `iconutil -c iconset <Assets.car> AppIcon -o <temporary folder>` succeeds, and `icon_512x512@2x.png` in the output is 1024 px wide. The file has the `AppIcon` asset, not only a file with the correct name. The test fails before the change, because the bundle has no `Assets.car`.

The suite already has a helper that runs a tool and returns its output. Do not use `NSWorkspace.icon(forFile:)`, because Launch Services caches icons.

### Preview for approval

- Flat icon as macOS 14 and 15 show it: `iconutil -c iconset build/icon/Assets.car AppIcon -o build/icon-preview/flat.iconset`. Then show `icon_512x512@2x.png` (1024 px) and `icon_16x16@2x.png`.
- Appearances as macOS 26 shows them: `ictool --export-preview macOS <Light|Dark|TintedLight|ClearLight> 512 512 1 <file>.png`.
- Put the PNG files side by side in one page (an Artifact or a Finder window) for the user. The Read tool shows each PNG to the agent. Give the user the paths.
- After `make run`, check the Dock and Finder icon on the development Mac. Record this as a manual check in the run ledger. Check it also on a macOS 26 Mac if one is available.

## Recommended pipeline

| Item | Value |
|---|---|
| Source | `Support/AppIcon.icon/` (`icon.json`, `Assets/*.svg`), made in Icon Composer or written by hand |
| Build step | Plan of 2026-09-27, in `scripts/bundle.sh`. Built in `scripts/icon.sh`, and `scripts/bundle.sh` copies the files (decision 0026): `xcrun actool Support/AppIcon.icon --compile build/icon --app-icon AppIcon --platform macosx --target-device mac --minimum-deployment-target 14.0 --include-all-app-icons --output-partial-info-plist build/icon/partial.plist --errors --warnings`, then copy `Assets.car` and `AppIcon.icns` to `Contents/Resources/` before `codesign` |
| Outputs in the bundle | `Contents/Resources/Assets.car`, `Contents/Resources/AppIcon.icns` |
| Info.plist keys | `CFBundleIconName = AppIcon`, `CFBundleIconFile = AppIcon` in `Support/Info.plist` |
| Preview target | `make icon-preview`: compiles the icon, then writes the flat PNG files (`iconutil`) and the appearance PNG files (`ictool`) to `build/icon-preview/` |
| Test | One new test in `AppBundleTests`, run by `make test-app` |
| New dependency | None. `actool` and `ictool` come with Xcode 26, which the repo already needs |

The plan was to add a row for `make icon-preview` to the Commands table of `AGENTS.md`. State on 2026-11-24: the table has no such row. The Makefile holds the target (`make icon-preview`), and `AGENTS.md` sends the reader to the Makefile for the other targets.

### One-way decisions

1. The format: a `.icon` file compiled to `Assets.car`, not a legacy `.icns` only. Changing back later is easy in code, but the art style (flat layers, no baked effects) follows this choice.
2. The concept and the colors are the brand of the app. Users learn the icon, so choose it with the user before the first release.
3. The asset name `AppIcon` is in `Info.plist`, in the build step, and in the test. It is cheap to change now and costs a rebuild of the icon cache later.

## Sources

1. Apple, Human Interface Guidelines, "App icons" (via the JSON at https://developer.apple.com/tutorials/data/design/human-interface-guidelines/app-icons.json). https://developer.apple.com/design/human-interface-guidelines/app-icons
2. Apple, "Creating your app icon using Icon Composer" (via https://developer.apple.com/tutorials/data/documentation/xcode/creating-your-app-icon-using-icon-composer.json). https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer
3. Apple, WWDC25 session 220, "Say hello to the new look of app icons". https://developer.apple.com/videos/play/wwdc2025/220/
4. Apple, WWDC25 session 361, "Create icons with Icon Composer". https://developer.apple.com/videos/play/wwdc2025/361/
5. Apple, `CFBundleIconName` and `CFBundleIconFile`. https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleiconname ; https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleiconfile
6. `iconutil(1)` man page. https://keith.github.io/xcode-man-pages/iconutil.1.html
7. Apple, Icon Composer download. https://developer.apple.com/icon-composer
8. Michael Tsai, "Separate Icons for macOS Tahoe vs. Earlier" (quotes John Siracusa, Václav Slavík, Avi Drissman). https://mjtsai.com/blog/2025/08/08/separate-icons-for-macos-tahoe-vs-earlier/
9. Schurigeln, "Creating app icons for macOS 11 and up" (1024 canvas, 824 body, corner radius 185.4). https://medium.com/design-bootcamp/creating-app-icons-for-macos-11-and-up-1132ccd479bc ; block/buzz issue 3272. https://github.com/block/buzz/issues/3272
10. Geometrical, "Apple's macOS 11 Big Sur Adopts iOS Icon Mask Shape for App Icons". https://www.geometrical.design/blog/apple-s-macos-11-big-sur-adopts-ios-icon-mask-shape-for-app-icons
11. Jeff Johnson, "macOS Tahoe forces all app icons into iOS squircles". https://lapcatsoftware.com/articles/2025/6/2.html
12. 9to5Mac, "macOS Tahoe put your apps in icon jail? Here's the fix". https://9to5mac.com/2025/08/08/macos-tahoe-fix-gray-box-icons/
13. Howard Oakley, "Last Week on My Mac: Tahoe the iconoclast". https://eclecticlight.co/2025/06/22/last-week-on-my-mac-tahoe-the-iconoclast/
14. aladh/Spotty pull request 261 (legacy `.icns` gray tile, fixed with `.icon` and `CFBundleIconName`). https://github.com/aladh/Spotty/pull/261
15. stablyai/orca issue 16495, "macOS Clear and Tinted icon styles are ignored because the packaged app only contains a legacy ICNS". https://github.com/stablyai/orca/issues/16495
16. Successful Software, "Updating application icons for macOS 26 Tahoe and Liquid Glass". https://successfulsoftware.net/2025/09/26/updating-application-icons-for-macos-26-tahoe-and-liquid-glass/
17. Hendrik Erz, "Supporting Liquid Glass Icons in Apps Without XCode". https://www.hendrik-erz.de/post/supporting-liquid-glass-icons-in-apps-without-xcode
18. ethbak/icon-composer-mcp README (`ictool` path and renditions). https://github.com/ethbak/icon-composer-mcp
19. Michael Tsai, "How to Export a Mac .icon File With the Proper Margins". https://mjtsai.com/blog/2025/10/02/how-to-export-a-mac-icon-file-with-the-proper-margins/
20. Probes (all in a local run folder, not in git):
    - `tools/`: `actool --version` (26.3), `iconutil`, `ictool`, Xcode 26.3, Icon Composer present.
    - `svg/`: Swift `NSImage` SVG render to 1024 and 16 px; `qlmanage` fails in the sandbox.
    - `compile/`: `.iconset` to `.icns` and back with `iconutil`; `actool` write failure inside the repo.
    - `icon-format/`: `actool` on `.xcassets` and `.icon` (targets 14.0 and 26.0), `assetutil --info`, body bounds 824 x 824 px.
    - `ictool/`: `ictool --export-preview` for Light, Dark, TintedLight, and ClearLight; Icon Composer `LSMinimumSystemVersion` 15.3.
    - `svg-layer/`: `.icon` with an SVG layer compiled by `actool`; flat 1024 px rendition with an 824 px body.
