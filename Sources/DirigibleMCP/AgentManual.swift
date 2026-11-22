import Foundation

/// The agent manual (decision 0051): the one owner of the MCP `instructions`, the text of
/// `dirigible --instructions`, the MCP prompts, and the skill. The core goes first and stays in
/// 2048 characters, the documented cut of Claude Code; the whole text stays in 6000.
package enum AgentManual {
    /// The phases of podcast work, in order. Each recipe has one, and the core gives one line for
    /// each phase: its rule, then the names of its recipes.
    enum Phase: CaseIterable, Sendable {
        case prepare, record, edit, produce, export

        var title: String { "\(self)".capitalized }

        /// The rule of the phase in the core. Only `.record` has one, and it has no recipe.
        var rule: String? {
            guard self == .record else { return nil }
            return "the `record` tool asks the user in the app; do not repeat a refused call. "
                + "`dirigible record <package> --seconds <seconds> --arm <track ID> --playhead <frame>` records at "
                + "once, with no consent sheet, and replaces the clips under it: run it only when the user asked for "
                + "a recording, at the frame that the user gives."
        }
    }

    /// One task that an agent often gets. The name is the MCP prompt name; its one argument is
    /// `package`.
    struct Recipe: Sendable {
        let phase: Phase
        let name: String
        let title: String
        let summary: String
        let steps: String
    }

    /// The recipes in phase order.
    static let recipes = [
        Recipe(
            phase: .prepare, name: "prepare-tracks", title: "Prepare the tracks",
            summary: "Add the tracks of a recording and route each one to an input device, an app, or a call.",
            steps: "`devices` lists the input devices and `apps` the apps that can be a source; add a track with "
                + "`track_add`; route it with `track_route` and `device` with `channels`, or `app`; for a call, "
                + "`track_add_call`. Report each track and its source."),
        Recipe(
            phase: .edit, name: "cut-a-range", title: "Cut a range",
            summary: "Remove a time range from all tracks and keep them in sync.",
            steps: "`clip_ripple_delete`: `from` and `to` are arrays, one item for each range; read `session_info` "
                + "(use `compact`) again. `clip_heal` joins the splits that stay after the cuts: the sound does not "
                + "change. \"no join to heal\" is normal: a cut leaves a gap in the file. A heal changes clip IDs: "
                + "run `transcript_words` again."),
        Recipe(
            phase: .edit, name: "cut-from-transcript", title: "Cut from a transcript",
            summary: "Find words in a transcript with word times, and cut them from all tracks in sync.",
            steps: RecordRequest.loudnessRule + " The transcript is of an `export` of the current session from "
                + "frame 0 with each track heard, or of one take: give `take`; time 0 is its record start. "
                + "`export` a .wav file for Whisper, or `transcribe` the track; if the export says that a track is "
                + "muted or not soloed, stop and ask the user. Turn on word timestamps (Whisper). For a transcript of the user, "
                + "ask which it is. Run `transcript_import` with the `path` of the Whisper JSON, WebVTT, or SRT file "
                + "and a `track`; give `text` only for a short transcript. Many skipped words mean a wrong `take`. "
                + "Import the transcript once, on one track. When `transcript_import` reports cues, stop and ask the "
                + "user: a cut removes each whole cue. The words follow the clips of the import track: edit all "
                + "tracks together. Find each passage with `transcript_words` with `match`. A cut on a closed "
                + "package saves at once: list each passage with its words and seconds, and get consent before the "
                + "cut, unless the user agreed. Run one `transcript_cut` with all the occurrences; report "
                + "each cut in seconds. Each edit makes the occurrences stale: run `transcript_words` again before "
                + "the next cut."),
        Recipe(
            phase: .produce, name: "check-levels", title: "Check the levels",
            summary: "Measure the loudness of each clip, level the session, and report the change. "
                + "For a speech clip whose level moves inside it, run `clip_level_over_time`.",
            steps: "run `loudness`, `level`, then `loudness` again; report each clip before and after."),
        Recipe(
            phase: .produce, name: "add-sound", title: "Add a sound clip",
            summary: "Import a sound clip, such as music or a jingle, at a frame, and fade it.",
            steps: "the imported clip replaces the clips under it, so put it on a new track from `track_add` with the "
                + "layout of the file, or in a range of a track that has no clip; "
                + "`import` with `file` (an absolute path), `track`, and `at` (a frame) shapes the clip in one "
                + "call: `offset` and `length` (frames of the made WAV) take a range of the file, `db` sets the gain "
                + "relative to the file level, with no auto level, `fade_in` and `fade_out` set the fades, "
                + "and `id` names the clip. For more parts of one file, import it once, then run `clip_place` with "
                + "the file ID and `clip_fade` for each part: each import converts the whole file."),
        Recipe(
            phase: .produce, name: "lower-music", title: "Lower the music under the voice",
            summary: "Lower the music under a voice.",
            steps: "`duck` with the roles of `track_role`, or with `speech` and `music`; for a user range, "
                + "`clip_gain_range`, `db` -16."),
        Recipe(
            phase: .produce, name: "add-chapter", title: "Add a chapter",
            summary: "Add a chapter marker at a time.",
            steps: "`marker_set` with `kind` chapter and `at`. For a chapters file, run `chapters_import` "
                + "with `path` (Podcasting 2.0 JSON) and `at` (the frame of 0 s). Give `replace` to remove the old "
                + "chapters first: each image stays on the chapter of the file at the same time. A chapter with an "
                + "image that the file leaves out blocks `replace`: run `marker_remove` for it first."),
        Recipe(
            phase: .export, name: "prepare-for-publishing", title: "Prepare for publishing",
            summary: "Set the episode details, level the session, and export an MP3 at the podcast loudness.",
            steps: "read `session_info` (use `compact`) and `episode_get`; ask for a missing title or show and set "
                + "them with `episode_set`; when the session has chapters, make sure one is at frame 0; run "
                + "`level`, then `export` with `out` an .mp3 file and `loudness` podcast; `chapters_export` with "
                + "`out` a .txt file gives the show-notes chapter list; `file_prune` with `dry_run` lists "
                + "the unused files of a closed package (the app: File > Remove Unused Files); "
                + "report the loudness line and the file path."),
    ]

    /// The manual with the quoted path of the running `dirigible`, after symlinks. realpath(3), not
    /// `resolvingSymlinksInPath()`, which gives /tmp for /private/tmp: an allow rule of the client
    /// names the real path.
    package static var instructions: String {
        var path = Bundle.main.executableURL?.path ?? "dirigible"
        if let real = realpath(path, nil) {
            path = String(cString: real)
            free(real)
        }
        return manual(pathLine: pathLine(quoted: shellQuoted(path)))
    }

    static func pathLine(quoted path: String) -> String { "The CLI is \(path). Below, `dirigible` means that path." }

    /// The path rule of the skill: a link in a skills folder points into the app.
    static let bundledPathLine = """
        The CLI is in the app that holds this skill. First run `realpath <the base folder of this skill>`: a \
        link in a skills folder points into the app, so the result is `<app>/Contents/Resources/skills/dirigible`, \
        and the CLI is `<app>/Contents/Helpers/dirigible`. Only when the result is not in an app (a copy of this \
        skill), use `/Applications/Dirigible.app/Contents/Helpers/dirigible`, or ask the user for the app path. \
        Below, `dirigible` means that path.
        """

    /// The rules, from the description to the no-tool rule.
    static func core(pathLine: String) -> String {
        """
        Dirigible records and edits podcasts on macOS. The tools read and edit session packages: folders that end \
        in .dirigible.

        \(pathLine)

        Rules:
        - Change only what the user asks for. Ask before other changes.
        - Give `package` as an absolute path. Call `session_info` first: it gives the sample rate and the IDs of \
        the tracks, clips, files, and markers. The tools take IDs, not names.
        - Times are frames: frame = seconds x sample rate, rounded. `silences`, `nearest_pause`, and `meter` read audio by time.
        - A split or a ripple gives new clip IDs. After an edit, read `session_info` again and report it. Saves keep backups: `backup_list`.
        - The ripple tools move the later clips and markers. Give no `track` to keep all tracks in sync. Give all \
        the ranges of a cut in one call.
        - On a package open in the app, an edit is one undo step there when Settings > Let Agents Edit Open \
        Sessions is on; else it is refused. On "is busy in Dirigible", if the text asks the user, ask and wait. \
        Else try again after a few seconds, at most 3 times.
        - `track_match_voice` matches tracks to a voice.

        Phases and recipes, in order:
        \(phaseLines)
        - For work with no tool, run the CLI in a shell, for example `dirigible take finalize <package>`. \
        `dirigible help <command>` gives the options. A command refuses a package that is open in the app.
        """
    }

    /// One line for each phase: its rule, then the names of its recipes.
    static var phaseLines: String {
        Phase.allCases.map { phase in
            let names = recipes.filter { $0.phase == phase }.map(\.name)
            let parts = [phase.rule, names.isEmpty ? nil : names.joined(separator: ", ") + "."].compactMap { $0 }
            return "- \(phase.title): " + parts.joined(separator: " ")
        }.joined(separator: "\n")
    }

    /// The core, then one line for each recipe, then the pre-roll line, the raw line, and the report line.
    static func manual(pathLine: String) -> String {
        core(pathLine: pathLine) + "\n\nRecipes (also MCP prompts):\n"
            + recipes.map { "- \($0.name): \($0.steps)" }.joined(separator: "\n") + "\n\n" + preRollLine + "\n"
            + rawLine + "\n\n" + reportLine
    }

    /// The pre-roll of a take (decision 0070). Outside the core, which has no room.
    static let preRollLine = "`record` takes `pre_roll` (0 to 10). CLI: `--pre-roll <seconds>`."

    /// What a role is and what reads it (decision 0060). In the skill only: the manual has no room
    /// under its 6000 characters.
    static let roleLine =
        "A role from `track_role` is a label: it changes no sound. `duck`, `clip_denoise`, and `export_stems` "
        + "read it. "
        + "A track with no role is in no list of `duck`: give `speech` or `music`."

    /// What Match Voice takes (decision 0074). In the skill only: the manual has no room under its 6000
    /// characters.
    static let matchLine =
        "`track_match_voice` gives tracks a live EQ curve toward a reference voice: `reference` (a clip ID, with "
        + "`from` and `to` for a part of it) and `tracks`; `amount` is 1 to 100, and a new match takes 75. Each "
        + "side needs 10 s of voice, and no audio file changes. With no `reference`, `amount` and `bypass` change "
        + "a match, and `remove` removes it."

    /// What Sync Clip takes (decision 0076). In the skill only: the manual has no room under its 6000
    /// characters.
    static let syncLine =
        "`clip_sync` moves a clip onto its audio on another track, for a recording with no shared clock: `clip`, "
        + "`to` (the reference track), `within` (seconds on each side, 1800 by default), and `drift`. Without "
        + "`drift`, it moves the whole clip by one lag and does not correct a drift. With `drift` true, a clip of "
        + "5 min or more also gets its clock drift fixed, with new audio files."

    /// What the preset tools and `preset` take (decision 0080). In the skill only: the manual has no room
    /// under its 6000 characters.
    static let presetLine =
        "`preset_set` and `preset_remove` change the export presets of a session. A preset has a name, a `format` "
        + "(wav, flac, aac, or mp3), and the options of that format. `export` with `preset` writes one file for each "
        + "preset: the name of a session preset, or the built-in master or podcast. `out` is then <folder>/<prefix>, "
        + "with no file extension, and the options of the call must not go with `preset`. A session preset with the "
        + "name of a built-in hides that built-in."

    /// What Import Session takes (decision 0075). In the skill only: the manual has no room under its 6000
    /// characters.
    static let sessionImportLine =
        "`import_session` (CLI: `dirigible import-session <package> <source>`) adds the tracks of another session "
        + "package as new last tracks, for two recordings of one conversation: `source` (an absolute path), `at` "
        + "(frames of this session added to the source positions; a negative value drops the source head), and "
        + "`markers`. A track with an app route imports muted, and the source does not change. The reply gives the "
        + "new track IDs, `marker <id>` for each new marker, and a `Left out:` line when markers land outside "
        + "0...2^40."

    /// The raw files that stay (decision 0071). Outside the core, which has no room.
    static let rawLine =
        "`rawKept` in `session_info` (CLI: `raw <stem> kept: <reason>`) names each kept raw CAF and why."

    /// The problem report (decision 0059). Outside the core, which has no room.
    static let reportLine =
        "When Dirigible fails or hangs, `dirigible diagnostics collect <zip>` saves a report with no private "
        + "names; the user sends it."

    /// The `SKILL.md` text: the frontmatter, the core with the path rule of the bundle, the command of
    /// each tool from the tool table, and each recipe in full.
    package static var skill: String {
        let tools = Tool.all.map { "| \($0.name) | dirigible \($0.command) |" }.joined(separator: "\n")
        let recipeText = Phase.allCases.map { phase in
            let phaseRecipes = recipes.filter { $0.phase == phase }
            let body =
                phaseRecipes.isEmpty
                ? "No recipe: the \(phase.title) line of the rules gives the rule.\n"
                : phaseRecipes.map { "#### \($0.title) (\($0.name))\n\n\($0.summary) Steps: \($0.steps)\n" }
                    .joined(separator: "\n")
            return "### \(phase.title)\n\n" + body
        }
        return """
            ---
            name: dirigible
            description: Read and edit Dirigible podcast sessions (.dirigible packages) with the dirigible CLI and \
            the Dirigible MCP tools. Use it to prepare the tracks and their sources, record, edit (cut a range or \
            the words of a transcript), produce (levels, sound clips, chapters), and export an episode.
            ---

            # Dirigible

            \(core(pathLine: bundledPathLine))

            ## Tools and commands

            With no MCP server, run the command of a tool in place of the tool. The tool arguments are options \
            of the command, with - in place of _; some, such as clip IDs, come after the package with no option \
            name. `dirigible help <command>` gives the exact form. For `session_info`, run \
            `dirigible info <package> --json`. \(rawLine) For `batch`, run `dirigible batch <package> <file>`: the file holds \
            the `calls` array. A batch is one undo step in the app and one save on the files. A step edits \
            session.xml only, with no file argument, and `transcript_cut` is not a step. A later step names a new \
            object by the ID that the earlier step gave; `clip_split_at` and `clip_paste` give theirs in the result \
            lines. Each step sees the session after the earlier steps: a ripple moves the later frames, and the \
            right part of a cut clip gets a new ID. Send ripple cuts from the last to the first, or use one call \
            with many ranges.

            `transcribe` takes `model_file`, the absolute path of a ggml whisper model file of the user, in place \
            of `model`. Before it loads the file, Dirigible checks it in a helper process: \
            `dirigible model check <path>`. A file that the check refuses gives the reason and changes nothing.

            \(preRollLine)

            \(roleLine)

            \(matchLine)

            \(syncLine)

            \(presetLine)

            \(sessionImportLine)

            | Tool | Command |
            |---|---|
            \(tools)

            ## Recipes

            \(recipeText.joined(separator: "\n"))
            ## Problem reports

            \(reportLine)

            """
    }
}

extension AgentManual {
    /// The `prompts/list` entries: one for each recipe, with the one argument `package`.
    static var promptList: [[String: Any]] {
        recipes.map { recipe in
            [
                "name": recipe.name, "title": recipe.title, "description": recipe.summary,
                "arguments": [
                    [
                        "name": "package", "description": "The absolute path of the session package.",
                        "required": true,
                    ]
                ],
            ]
        }
    }
}

extension AgentManual.Recipe {
    /// The `prompts/get` result: one user message with the recipe and the package path.
    func prompt(package: String) -> [String: Any] {
        // A client can cut an argument at a space (code gate 1 item 10).
        let text =
            "\(title) in the session package \(package). If no package is at that path, ask the user for the full "
            + "path. Steps: \(steps)"
        return ["description": summary, "messages": [["role": "user", "content": ["type": "text", "text": text]]]]
    }
}

extension Tool {
    /// The tools whose name does not follow the name rule of decision 0041.
    static let commandNames = [
        "session_create": "create", "session_info": "info", "episode_get": "episode show",
        "nearest_pause": "nearest-pause", "silence_edit": "silence-edit", "export_stems": "export-stems",
        "import_session": "import-session",
    ]

    /// The `dirigible` command words of the tool: the first word, then the other words with `-`.
    var command: String {
        if let command = Self.commandNames[name] { return command }
        let words = name.split(separator: "_")
        return words.count == 1 ? name : words[0] + " " + words.dropFirst().joined(separator: "-")
    }
}

/// The `Contents` folder of the app that holds `executable` at `<name>.app/Contents/<folder>/<tool>`,
/// after symlinks, or nil outside an app.
package func appContents(of executable: URL) -> URL? {
    let contents = executable.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
    guard contents.lastPathComponent == "Contents", contents.deletingLastPathComponent().pathExtension == "app"
    else { return nil }
    return contents
}

/// `text` in single quotes for a POSIX shell: each `'` becomes `'\''`.
package func shellQuoted(_ text: String) -> String {
    "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
}
