# 0029. The app route and session.xml version 2

- Status: accepted
- Date: 2026-10-02
- Accepted: 2026-10-02, after the architect synthesis and plan gates 1 and 2 of run `2026-10-02-app-sources`.
- Amends: 0003 (`<route app>` and version 2).
- Amended: 2026-10-27, run `2026-10-27-armed-app-track`. Input Levels taps an armed app track, so the prompt can come before a take (**Monitor**).

## Context

R12 records the audio of another app to its own track, as a device (0006). A track route held only device channels: `<route device="UID" channels="1 2"/>`. An app has no channels. The tap gives a mono or a stereo mixdown of all the processes of the app (0006).

0024 P6 says that a writer writes the lowest version that holds the data. P7 says that a change that an older reader would skip raises the version. A version 1 build reads `<route>` with no `device` attribute as a missing attribute, and a version 1 build that skips the element and saves loses the route.

## Decision

**Model.** `Route` is an enum with two cases: `.device(uid:channels:)` and `.app(bundleID:)`. The app case has no channels. The track layout picks the mono or the stereo mixdown. The compiler finds each caller that reads a device UID or channels.

**Checks.** `setRoute` and `setLayout` refuse an app route with an empty bundle ID (`.invalidRoute`) and a bundle ID with a control character (`.invalidText`, the 0003 text rule). A device route keeps its checks.

**Version.** `Session.fileVersion` is derived, never stored: 2 when one or more tracks have an app route, else 1. The writer writes it. So a session with no app route keeps the version 1 bytes, and a save after the last app route goes writes version 1 again. The newest version that the reader accepts is 2. The reader takes the newest version as a parameter, so a test acts as a version 1 build.

**Schema.** An app route is `<route app="BUNDLEID"/>` with no `device` and no `channels`. The reader refuses it in a version 1 file, with a `device` or a `channels` attribute, and with an empty ID.

| Value in session.xml | Reader result |
|---|---|
| `version` 3 or more | `.unsupportedVersion` |
| `version="2"` in a version 1 build | "newer version (version 2)" |
| `<route app>` in `version="1"` | `invalidValue(route, app)` |
| `app` with `device` or `channels` | `invalidValue(route, app)` |
| `app=""` or a control character | `.invalidRoute` or `.invalidText` |
| `version="2"` with no app route | accepted; the next save writes 1 |

**Identity of a segment.** `<capture deviceUID="app:BUNDLEID">` and the sidecar device UID are existing strings, so they need no version change (0024 P7).

**One track for each app.** The route check of a take keys an app by `app:BUNDLEID`, so a second armed track on the same app is refused as a channel in use.

**Monitor.** Input Levels (0015) meters an armed app track with a tap. So macOS shows the System Audio Recording prompt at the first tap of an armed app track while Input Levels is on: when the user turns Input Levels on, arms an app track, or routes an armed track to an app. Each is a user act. With Input Levels off, an arm makes no tap. A listened app track gets no tap (0044).

**CLI.** `dirigible track route` and `track layout` take `--app <bundle ID>` as a third route form beside `--device` with `--channels` and `--none`. Two forms together are a usage error (exit 64). `info --json` shows the session version. On macOS 14.0 and 14.1 (no process taps) `--app` exits 1 and changes nothing.

## Consequences

- A session with an app route does not open in a version 1 build. That build says that a newer version made it, and changes no file (0024 P4).
- A version 2 file that a user edits to remove its app routes saves as version 1.

## Alternatives considered

- **A route struct with a source field and optional channels.** Rejected: an app route with channels, or a device route without them, could exist.
- **A `#mono` suffix on the app key.** Rejected: it breaks the `app:BUNDLEID` identity of a segment.
- **Always write version 2.** Rejected by 0024 P6: an older build could not open a session with no new data.
