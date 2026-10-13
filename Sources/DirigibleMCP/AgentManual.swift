import Foundation

/// The agent manual (decision 0051): the one owner of the MCP `instructions`, the text of
/// `dirigible --instructions`, the MCP prompts, and the skill. The core goes first and stays in
/// 2048 characters, the documented cut of Claude Code; the whole text stays in 4000.
package enum AgentManual {
    /// One task that an agent often gets. The name is the MCP prompt name; its one argument is
    /// `package`.
    struct Recipe: Sendable {
        let name: String
        let title: String
        let summary: String
        let steps: String
    }

    static let recipes = [
        Recipe(
            name: "check-levels", title: "Check the levels",
            summary: "Measure the loudness of each clip, level the session, and report the change.",
            steps: "run `loudness`, then `level`, then `loudness` again; report each clip before and after."),
        Recipe(
            name: "prepare-for-publishing", title: "Prepare for publishing",
            summary: "Set the episode details, level the session, and export an MP3 at the podcast loudness.",
            steps: "read `session_info` and `episode_get`; ask for a missing title or show and set them with "
                + "`episode_set`; when the session has chapters, make sure one is at frame 0; run `level`; then run "
                + "`dirigible export <package> --out <file.mp3> --loudness podcast`; report the printed loudness line "
                + "and the file path."),
        Recipe(
            name: "cut-a-range", title: "Cut a range",
            summary: "Remove a time range from all tracks and keep them in sync.",
            steps: "`clip_ripple_delete` with `from` and `to` and no `track`; read `session_info` again."),
        Recipe(
            name: "add-chapter", title: "Add a chapter",
            summary: "Add a chapter marker at a time.",
            steps: "`marker_set` with `kind` chapter and `at` in frames."),
    ]

    /// The manual with the quoted path of the running `dirigible`, after symlinks.
    package static var instructions: String {
        let path = Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? "dirigible"
        return manual(pathLine: pathLine(quoted: shellQuoted(path)))
    }

    static func pathLine(quoted path: String) -> String { "The CLI is \(path). Below, `dirigible` means that path." }

    /// The path rule of the skill: a link in a skills folder points into the app.
    static let bundledPathLine = """
        The CLI is in the app that holds this skill. Run `realpath <the folder of this file>`: it gives \
        `<app>/Contents/Resources/skills/dirigible`, and the CLI is `<app>/Contents/Helpers/dirigible`. For a copy \
        of this skill, use `/Applications/Dirigible.app/Contents/Helpers/dirigible`, or ask the user for the app \
        path. Below, `dirigible` means that path.
        """

    /// The rules, from the description to the no-tool rule.
    static func core(pathLine: String) -> String {
        """
        Dirigible is a podcast recorder and editor for macOS. These tools read and edit session packages: \
        folders whose names end in .dirigible.

        \(pathLine)

        Rules:
        - Give `package` as an absolute path. Call `session_info` first: it gives the sample rate and the IDs of \
        the tracks, clips, files, and markers. The tools take IDs, not names.
        - Times are frames at the session rate: frame = seconds x sample rate. A `to` frame is the frame after the \
        last frame.
        - A split or a ripple gives new clip IDs. After an edit, read `session_info` again and report what it shows.
        - The ripple tools move the later clips and markers. Give no `track` to keep all tracks in sync.
        - On a package that is open in the app, an edit is one undo step there, only when Settings > Let Agents \
        Edit Open Sessions is on; else it is refused. A closed package saves at once, with no undo. "is busy in \
        Dirigible": wait a few seconds and try again, at most 3 times.
        - `dirigible record <package> --seconds <seconds> --arm <track ID> --playhead <frame>` records at once \
        from the routed devices, with no consent sheet, and replaces the clips under it. Run it only when the user \
        asked for a recording, at the frame that the user gives. The `record` tool asks the user in the app; do not \
        repeat a refused `record` call.
        - No tool reads the audio by time (silence, words): ask the user for the frame.
        - For work with no tool, run the CLI in a shell: `dirigible loudness <package>` (the loudness of each \
        clip), `dirigible level <package>` (-16 LUFS stereo, -19 LUFS mono), \
        `dirigible export <package> --out <file.mp3> --loudness podcast` (also .m4a, .wav, .flac), \
        `dirigible import <package> <audio file>`. `dirigible help <command>` gives the options. A command \
        refuses a package that is open in the app.
        """
    }

    /// The core, then one line for each recipe.
    static func manual(pathLine: String) -> String {
        core(pathLine: pathLine) + "\n\nRecipes (also MCP prompts):\n"
            + recipes.map { "- \($0.name): \($0.steps)" }.joined(separator: "\n")
    }

    /// The `SKILL.md` text: the frontmatter, the core with the path rule of the bundle, and each
    /// recipe in full.
    package static var skill: String {
        let recipeText = recipes.map { "### \($0.title) (\($0.name))\n\n\($0.summary) Steps: \($0.steps)\n" }
        return """
            ---
            name: dirigible
            description: Read and edit Dirigible podcast sessions (.dirigible packages) with the dirigible CLI and \
            the Dirigible MCP tools. Use it to check the levels, cut a range, add chapters, and export an episode.
            ---

            # Dirigible

            \(core(pathLine: bundledPathLine))

            ## Recipes

            \(recipeText.joined(separator: "\n"))
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
        let text = "\(title) in the session package \(package). Steps: \(steps)"
        return ["description": summary, "messages": [["role": "user", "content": ["type": "text", "text": text]]]]
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
