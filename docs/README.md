# Docs map

This file lists every doc of the repo, by group. The [README](../README.md) links here.

## For users and contributors

- [User guide](guide.md): how to record, edit, and export an episode, and the list of menu commands. The app shows it in Help.
- [Contributing](CONTRIBUTING.md): who can open issues and pull requests, and how the project works.
- [Security](SECURITY.md): how to report a security problem.
- [How Dirigible was made](provenance.md): the statement of how the code was made, and the third-party parts.

## Requirements

- [Product brief](requirements/brief.md): the original request and the requirement IDs.
- [Features](requirements/features.md): the one place that holds the state of each feature.
- [Releases](requirements/releases.md): the release order and the version scheme.

## Glossary and principles

- [Glossary](../CONTEXT.md): the terms of the product and the code.
- [Engineering principles](principles.md): the rules that skills and reviewers cite.

## Rules for agents and developers

- [AGENTS.md](../AGENTS.md): commands, git rules, and the workflow of the repo agents.
- [Coding standards](../CODING_STANDARDS.md): design, concurrency, and safety rules for Swift code.

## Decisions

Each record has a number, a status, and an area: product (what the app does or how it is built) or workflow (how the project runs). The numbers 0058, 0068, and 0069 are not used. A record can name a run or a `.scratchpads/` path: these are local working notes that are not in the repo.

| Number | Title | Status | Area |
|---|---|---|---|
| [0001](decisions/0001-native-swift-stack.md) | Native Swift app, built with SwiftPM only | accepted | product |
| [0002](decisions/0002-module-map.md) | Module map: three libraries and a thin app | accepted | product |
| [0003](decisions/0003-session-file-format.md) | Session file: a document package with our own XML | accepted | product |
| [0004](decisions/0004-capture-pipeline.md) | Capture pipeline: one IOProc per device, CAF segments, recovery on open | accepted | product |
| [0005](decisions/0005-swift-atomics.md) | Dependency: apple/swift-atomics for the capture ring buffer | accepted | product |
| [0006](decisions/0006-app-audio-process-taps.md) | App audio: Core Audio process taps, one private aggregate per tap | accepted | product |
| [0007](decisions/0007-export-formats-and-encoders.md) | Export: WAV, AAC, FLAC through AVAudioFile; MP3 through LAME | accepted | product |
| [0008](decisions/0008-loudness-and-auto-level.md) | Loudness: our own BS.1770 meter, -16 LUFS export, static clip gain | accepted | product |
| [0009](decisions/0009-noise-reduction.md) | Noise reduction: AUSoundIsolation offline, vDSP spectral gating as fallback | accepted | product |
| [0010](decisions/0010-ui-strings.md) | UI strings: .lproj tables in the app bundle, language through AppleLanguages | accepted | product |
| [0011](decisions/0011-command-line-front-end.md) | Command-line front end: `dirigible`, built on swift-argument-parser | accepted | product |
| [0012](decisions/0012-capture-files-and-package-lock.md) | Capture files, the sidecar format, and the package lock | accepted | product |
| [0013](decisions/0013-live-capture.md) | Live capture: C callbacks, the ring in the device writer, device events, disk and sleep | accepted | product |
| [0014](decisions/0014-session-window.md) | The session window: one AppKit window per package, autosave through Studio, no Versions yet | accepted | product |
| [0015](decisions/0015-input-monitor.md) | Input monitor: an explicit toggle, a device writer with no take, and one device-list listener | accepted | product |
| [0016](decisions/0016-player-and-transport.md) | Player and transport: our own mix render into one AVAudioPlayerNode, reverse JKL with hold, keys that yield to text | accepted | product |
| [0017](decisions/0017-timeline-view.md) | Timeline view: an AppKit document view with own pixels, peaks in the user cache | accepted | product |
| [0018](decisions/0018-edit-commands.md) | Edit commands: bulk Session edits, a window clipboard, and an Edit menu that routes through the responder chain | accepted | product |
| [0019](decisions/0019-export.md) | Export: one ExtAudioFile writer, a mono fold in our code, a Studio export job, and a replace only over the confirmed item | accepted | product |
| [0020](decisions/0020-timeline-gesture-model.md) | Mouse edits: a DirigibleTimeline library with one pure gesture model, a preview outside SwiftUI state, and a commit that carries its base | accepted | product |
| [0021](decisions/0021-recovery-tools.md) | Recovery tools: the take anchor file, the placement of one segment, and a finish without unreadable audio | accepted | product |
| [0022](decisions/0022-timeline-lane-layer.md) | Timeline lanes: one layer of IOSurfaces written in place, with buffer age | accepted | product |
| [0023](decisions/0023-ui-shell.md) | UI shell: an AppKit toolbar beside the window, frozen identifiers, a resizable header ruler | accepted | product |
| [0024](decisions/0024-file-format-versioning.md) | File-format versioning: one integer version per file, and an older build never changes a newer file | accepted | product |
| [0025](decisions/0025-timeline-navigation.md) | Timeline navigation: an overview strip in its own view, one pure navigation value, the clip view owns the origin | accepted | product |
| [0026](decisions/0026-app-icon.md) | App icon: one Icon Composer source compiled by actool at target 14.0, concept W1 "waveform window" | accepted | product |
| [0027](decisions/0027-start-window.md) | A start window that AppDelegate owns, in place of the launch Open panel and the New Session save panel | accepted | product |
| [0028](decisions/0028-proportional-checks-and-reflect-governance.md) | Checks in proportion to the change, and rules that govern reflect | accepted | workflow |
| [0029](decisions/0029-app-route.md) | The app route and session.xml version 2 | accepted | product |
| [0030](decisions/0030-app-tap-owner.md) | The owner of an app tap: the writer slot of one appearance, on the writer queue | accepted | product |
| [0031](decisions/0031-auto-level-placement-and-undo.md) | Auto-level after the take write, and its own undo entry | accepted | product |
| [0032](decisions/0032-export-loudness-limiter-and-dither.md) | Export loudness: two passes, our own look-ahead true-peak limiter, and seeded TPDF dither | accepted | product |
| [0033](decisions/0033-loudness-meter.md) | Loudness meter: a strip below the lanes, the values of the heard frame, a short-term value per armed track | accepted | product |
| [0034](decisions/0034-vendored-c-and-mp3-encoder.md) | Vendored C code: LAME 4.0 as CLame, warnings fixed at the cause | accepted | product |
| [0035](decisions/0035-clip-fades.md) | Clip fades: session version 3, one quarter-sine curve, Command-F | accepted | product |
| [0036](decisions/0036-crossfades.md) | Crossfades at a butt join: session version 4, paired lengths on both clips, the sounding clip | accepted | product |
| [0037](decisions/0037-ripple-edit.md) | Ripple edit: all tracks by default, markers follow, one shift mutator, and no ripple under a split take | accepted | product |
| [0038](decisions/0038-clip-selection.md) | Clip selection: one Selection enum with a range or a clip set, Command-click on a clip, and a group move with one nudge | accepted | product |
| [0039](decisions/0039-track-mute-and-solo.md) | Track mute and solo: session flags in version 5, one heard rule, a Player crossfade | accepted | product |
| [0040](decisions/0040-file-import.md) | File import: a 24-bit WAV copy at the session rate, a blocking studio operation, one undo entry | accepted | product |
| [0041](decisions/0041-mcp-server.md) | MCP server: `dirigible mcp` with its own JSON-RPC layer | accepted | product |
| [0042](decisions/0042-paste-across-packages.md) | Paste across packages: one app clipboard, one copy function, and copies that stay after Undo | accepted | product |
| [0043](decisions/0043-session-backups.md) | Session backups: copies of session.xml in the package, no macOS Versions | accepted | product |
| [0044](decisions/0044-record-monitor.md) | Record monitor: a Listener per device with its own IOProc and a default output unit | accepted | product |
| [0045](decisions/0045-episode-metadata.md) | Episode metadata: one episode element in session.xml version 6, artwork files in the package, and an own ID3v2.3 writer | accepted | product |
| [0046](decisions/0046-mcp-in-app.md) | MCP server in the running app: a Unix socket, the `dirigible mcp` bridge, and `AgentServer` | accepted | product |
| [0047](decisions/0047-remove-unused-files.md) | Remove unused clip files: the Trash, and the files that a backup or an undo entry uses | accepted | product |
| [0048](decisions/0048-record-with-consent.md) | Record with consent: one `record` call that waits 20 s for the answer of the user | accepted | product |
| [0049](decisions/0049-mcp-progress-and-cancel.md) | Progress and cancel of an MCP tool call | accepted | product |
| [0050](decisions/0050-agent-record-grant.md) | Agent record grant: a window grant, the notice of an agent take, and the agent log | accepted | product |
| [0051](decisions/0051-agent-manual.md) | The agent manual: one owner for the MCP instructions, the prompts, the skill, and `dirigible --instructions` | accepted | product |
| [0052](decisions/0052-vari-speed.md) | Vari-speed: a speed unit in the Player graph only at speeds other than 1x | accepted | product |
| [0053](decisions/0053-split-stereo.md) | Split stereo to mono writes two mono files for each run of clips | accepted | product |
| [0054](decisions/0054-render-through-an-effect.md) | Render through an effect: clips render once into a new WAV, with no session format change | accepted | product |
| [0055](decisions/0055-transcript-storage.md) | Transcripts: words anchored to audio files, stored in a write-once file per transcript | accepted | product |
| [0056](decisions/0056-new-clip-files.md) | New clip files: one batch type for the bytes, one Core call for the record | accepted | product |
| [0057](decisions/0057-render-origin.md) | A rendered file keeps its origin: the input file, the treatment, and the added gain | accepted | product |
| [0059](decisions/0059-diagnostics.md) | Diagnostics: a journal for each launch and a hang watchdog | accepted | product |
| [0060](decisions/0060-gain-envelope-roles-ducking.md) | Gain envelope, track roles, and ducking | accepted | product |
| [0061](decisions/0061-take-time-map.md) | Take time: a map from the take to the timeline, the sync state, and SRT transcripts | accepted | product |
| [0062](decisions/0062-read-by-time.md) | Read the audio by time: one window scan, silences, the nearest pause, and the range meter | accepted | product |
| [0063](decisions/0063-agent-batch.md) | Agent batch: many edit calls as one undo step | accepted | product |
| [0064](decisions/0064-repair-effects.md) | Repair effects: own DSP stages in the clip render, and their origin elements | accepted | product |
| [0065](decisions/0065-whisper-transcription.md) | Transcription in the app: whisper.cpp as the source target CWhisper, a model download, and a job on file spans | accepted | product |
| [0066](decisions/0066-silence-tool.md) | The silence tool: one silence plan, one edit, a scan that a stale session stops | accepted | product |
| [0067](decisions/0067-export-one-file-for-each-chapter.md) | Export one file for each chapter or marker: parts in DirigibleCore, one export job for the set, and a split argument of export | accepted | product |
| [0070](decisions/0070-pre-roll.md) | Pre-roll: playback during a pre-roll take, an anchor at the heard punch point, a floor at the playhead | accepted | product |
| [0071](decisions/0071-raw-capture-removal.md) | Raw capture removal after finalize | accepted | product |
| [0072](decisions/0072-session-archive.md) | Session archive: FLAC clip files with an archive attribute | accepted | product |
| [0073](decisions/0073-follow-tracks.md) | Follow tracks: a track flag in session.xml version 16, whole-clip moves in a ripple, and a refusal on overlap | accepted | product |
| [0074](decisions/0074-voice-match.md) | Voice match: a live EQ stage of the track, after the rendered levels | accepted | product |
| [0075](decisions/0075-import-session.md) | Import Session: one paste of a whole-session excerpt into new tracks, at the source positions plus an offset | accepted | product |
| [0076](decisions/0076-waveform-sync.md) | Sync a clip to a track by its audio waveform | accepted | product |
| [0077](decisions/0077-drift-link.md) | Drift fit: a drift-corrected file keeps a link to its source, apart from the render chain | accepted | product |
| [0078](decisions/0078-stem-export.md) | Stem export: one file for each track or role, in a folder that appears whole | accepted | product |
| [0079](decisions/0079-session-templates.md) | Session templates: a template is a session package, and a new session is a copy of it with the episode data removed | accepted | product |
| [0080](decisions/0080-export-presets.md) | Export presets: named export options in session.xml, two built-in presets in code, and one export job for several presets | accepted | product |
| [0081](decisions/0081-favorites-bins.md) | Clip bins in session.xml, and Favorites as one Dirigible package in Application Support | accepted | product |

## Research

Each note holds the sources and the findings that a decision or a feature used.

### Recording and capture

- [The armed app track: the level meter and the permission state before a take](research/armed-app-track.md)
- [Autosave, session backups, and revert: other editors and macOS Versions](research/autosave-backups.md)
- [Audio capture](research/capture.md)
- [Diagnostics for a hang at record start: research and design](research/diagnostics.md)
- [Observation cancel cost and registration build-up](research/observation.md)
- [PAC mask for the frame-pointer walker on macOS arm64](research/pac-mask.md)
- [Pre-roll recording (F08) and vari-speed playback (F18)](research/preroll-varispeed.md)
- [Core Audio process taps: setup, permission, helper processes, and Hindenburg](research/process-taps.md)
- [Raw recording files in Hindenburg PRO, REAPER, Audition, Logic Pro, and Audio Hijack](research/raw-recording-files.md)
- [Record monitor: how Hindenburg PRO, Logic Pro, and GarageBand let the user hear an input](research/record-monitor.md)
- [Record time left: reference behavior](research/record-time.md)
- [Recording offset in other editors](research/recording-offset.md)
- [Recovery of recordings and sessions in Hindenburg PRO](research/recovery-tools.md)
- [Markers during a take: Hindenburg and other editors](research/take-markers.md)
- [take-sync (reference behavior of editors and the SRT format)](research/take-sync.md)

### Editing

- [Audacity and SoundCraft for Replace, room tone, Duplicate, and Split Stereo](research/audacity-soundcraft.md)
- [Copy, Cut, and Paste of a clip set in other editors](research/clip-set-clipboard.md)
- [cut edges of a text cut (F111)](research/cut-edges.md)
- [Drag modes: reference behavior in REAPER, Final Cut Pro, Logic Pro, and Hindenburg PRO](research/drag-modes.md)
- [Edit commands in Hindenburg PRO 2](research/edit-commands.md)
- [a drop on an empty session, and a click in an empty lane](research/empty-drop-lane-click.md)
- [Clipboard bins and Favorites in Hindenburg and other editors](research/favorites-bins.md)
- [File import: placement, track, conversion, and feedback](research/file-import.md)
- [Hindenburg edit tools: Replace, room tone fill, Duplicate, Split stereo](research/hindenburg-edit-tools.md)
- [reference behavior for Import Session (F151)](research/import-session.md)
- [Logic Pro and Audition: Replace, room tone fill, Duplicate, Split stereo](research/logic-audition-edits.md)
- [Mouse edits on the lanes in Hindenburg PRO](research/mouse-edits.md)
- [Multi-region selection in other editors](research/multi-clip-selection.md)
- [Multi-range ripple delete in other editors](research/multi-range-delete.md)
- [Paste of clips into another session: other editors and Apple clone facts](research/paste-across-packages.md)
- [read-by-time (silence list, nearest pause, level and loudness of a range)](research/read-by-time.md)
- [Ripple edit in Hindenburg, Final Cut Pro, Logic Pro, GarageBand, and three other editors](research/ripple-edit.md)
- [silence tools](research/silence.md)
- [Snap in the timeline (F82)](research/snap.md)
- [Timeline edits: reference behavior](research/timeline-edits.md)

### Levels, repair, and effects

- [Automatic level in reference apps](research/auto-level-reference-apps.md)
- [Gain envelope, track roles, and ducking in reference apps](research/envelope-ducking.md)
- [Leveler, duck, and manual gain: reference behavior in other editors](research/envelope-ride.md)
- [Dynamic leveler ("Level Over Time") in reference apps](research/leveler.md)
- [Mute and Solo on a track in other editors](research/mute-solo.md)
- [AUSoundIsolation for the clip render (R8, F35)](research/render-denoise.md)
- [How editors let the user change processed clips later](research/render-link.md)
- [reference behavior of Reduce Rumble (F98), Repair Clipped Peaks (F99), and Soften Harsh S (F100)](research/repair-set.md)
- [Track volume fader in the track header (F94)](research/track-fader.md)
- [Voice match: EQ of a voice to a reference voice (F37)](research/voice-match.md)
- [Waveform sync of a clip to another track (F74)](research/waveform-sync.md)

### Transcripts

- [whisper.cpp v1.9.5 with the ggml Metal backend in the Dirigible SwiftPM target](research/metal.md)
- [Whisper models for Spanish with English tech terms, and grading without a reference](research/models.md)
- [Podcasting 2.0 chapters and transcripts, and the Argo app](research/podcasting-2.md)
- [transcript pane reference behavior](research/transcript-pane.md)
- [whisper.cpp in the Dirigible macOS app (F112)](research/whisper.md)

### Export, files, and metadata

- [export one audio file for each chapter or marker](research/chapter-export.md)
- [chapters export (JSON chapters, other apps, file name)](research/chapters.md)
- [chapter title, URL, and image inside the audio file](research/chapters-in-file.md)
- [Episode metadata in MP3 and M4A files](research/episode-metadata.md)
- [Export of the mix](research/export.md)
- [Export formats and audio DSP](research/export-and-dsp.md)
- [Export loudness with a true-peak limit: research findings](research/export-loudness.md)
- [Export presets and session templates in reference apps](research/presets-templates.md)
- [Session file formats](research/session-formats.md)
- [Stem export in reference apps](research/stem-export.md)

### Agents and MCP

- [Teach an agent to use the Dirigible MCP server](research/agent-onboarding.md)
- [reference behavior for the agent pack (heal, seamless crossfade, text chapters, unused media)](research/agent-pack.md)
- [Register the Dirigible MCP server in MCP clients](research/mcp-clients.md)
- [Progress, timeouts, and cancellation of long MCP tool calls in three clients](research/mcp-progress.md)
- [How macOS apps and automation interfaces behave when a command arrives during a modal dialog](research/modal-dialogs.md)
- [Remote transport control in DAWs and editors](research/remote-transport.md)
- [Undo grouping and batch tool calls](research/undo-grouping.md)

### UI and platform

- [App icon for Dirigible](research/app-icon.md)
- [Document window: saving, versions, file opening, and record keys](research/document-window.md)
- [Final Cut Pro editing features for a podcast editor](research/final-cut-pro.md)
- [Localized UI strings with SwiftPM (R13)](research/localization.md)
- [Logic Pro and GarageBand: features the first catalog missed](research/logic-garageband-update.md)
- [macOS UI shell for a pro audio app](research/macos-ui-shell.md)
- [Podcast features in Hindenburg PRO, GarageBand, and Logic Pro](research/podcast-features.md)
- [European Portuguese terms of the Dirigible UI (R13)](research/pt-pt-ui.md)
- [README and user guide for a macOS app](research/readme-and-guide.md)
- [reference apps 2 (Audacity, Adobe Audition, and a check of FCP, Logic Pro, Hindenburg PRO)](research/reference-apps-2.md)
- [session index (F76) and waveform vertical zoom (F78)](research/session-index-zoom.md)
- [Startup: what the app shows at launch, and how other apps start](research/startup.md)
- [Timeline clarity: ruler, in and out, clip header, clip edges, playhead, record-over notice](research/timeline-clarity.md)
- [Timeline playback and editing in Hindenburg PRO 2](research/timeline-playback.md)
- [Timeline view in Hindenburg PRO 2](research/timeline-view.md)
- [Track header controls at a tall lane, and the header of a recording track](research/track-header.md)
- [The window chrome and the Apple HIG](research/ui-chrome-hig.md)

### Agent workflow

- [Anthropic guidance on writing and maintaining agent instructions](research/agent-instruction-files.md)
- [Progressive disclosure of APIs and tools to agents](research/api-disclosure.md)
- [people and resources for the Dirigible agent workflow](research/apple-experts.md)
- [two claude.dev posts mapped to the workflow-speed run](research/claude-dev-posts.md)
- [Dex Horthy (HumanLayer) and Emil Kowalski skills](research/dex-emil.md)
- [Fog of war: Matt Pocock planning skills against deliver Phases 1 to 3](research/fog-of-war.md)
- [Expert views: self-editing agent instructions and small instruction files](research/instruction-files-experts.md)
- [Natalia Panferova and Nil Coalescing, for SwiftUI on macOS agent rules](research/panferova.md)
- [reference projects (Compositor, IceCubes, and other Swift apps)](research/reference-projects.md)
- [Self-improving instructions: what Anthropic says](research/self-editing-instructions.md)
- [published agent skills and rules for Swift and macOS](research/swift-mac.md)
- [SwiftFairy, its authors, and their network](research/swiftfairy.md)
- [Upstream skill sets: what changed and what we skipped](research/upstream-skill-sets.md)
- [Whole-workflow review: cursor/plugins, pstack, mattpocock/skills](research/whole-workflow.md)

## Workflow, for repo agents

- [Release cycle](workflow/release-cycle.md): the steering rules of the release plan.
- [Evals](workflow/evals.md): the regression set of the workflow docs.
- [Model routing](workflow/model-routing.md): the model and effort of each job of a deliver run.
- [Wiki](workflow/wiki.md): the local backlog, run log, and lessons.
- [Dependency check](workflow/dependency-check.md): the periodic check of the dependencies and the Whisper models.
- [Word budgets](workflow/budgets.tsv): the word count of each workflow doc.
- [Rule register](workflow/rules.tsv): each workflow rule, its verdict, and its source.
