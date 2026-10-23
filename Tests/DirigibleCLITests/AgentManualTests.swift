import Foundation
import Testing

@testable import DirigibleMCP

/// The text of the agent manual (decision 0051): its length, its CLI path, its record warning,
/// and its recipes.
struct AgentManualTests {
    /// A quoted path of 202 characters, longer than a real install path.
    static let longPath = "'/" + String(repeating: "a", count: 199) + "'"

    /// The documented cut of Claude Code is 2048 characters (C4). The whole text is a context-cost cap.
    static func fitsTheClientLimits(core: String, whole: String) -> Bool { core.count <= 2048 && whole.count <= 6000 }

    @Test func theCoreFitsTheClientLimit() {
        let pathLine = AgentManual.pathLine(quoted: Self.longPath)
        let core = AgentManual.core(pathLine: pathLine)
        let whole = AgentManual.manual(pathLine: pathLine)
        #expect(Self.fitsTheClientLimits(core: core, whole: whole), "core \(core.count), whole \(whole.count)")
        #expect(whole.hasPrefix(core) && core.contains("For work with no tool"), "the no-tool rule is in the core")
        // The boundary pair of the limit.
        let text = { (count: Int) in String(repeating: "x", count: count) }
        #expect(Self.fitsTheClientLimits(core: text(2048), whole: text(6000)))
        #expect(!Self.fitsTheClientLimits(core: text(2049), whole: text(6000)))
        #expect(!Self.fitsTheClientLimits(core: text(2048), whole: text(6001)))
    }

    @Test func thePathIsNamedOnce() {
        let manual = AgentManual.manual(pathLine: AgentManual.pathLine(quoted: Self.longPath))
        #expect(manual.components(separatedBy: Self.longPath).count == 2, "the path is not named once")
        let firstLines = manual.split(separator: "\n").prefix(3).joined(separator: "\n")
        #expect(firstLines.contains("The CLI is \(Self.longPath). Below, `dirigible` means that path."))
        #expect(!AgentManual.skill.contains(Self.longPath))
    }

    /// The CLI record is a real capability, so the manual names it with its warning (user
    /// decision of 2026-10-13, C16).
    @Test func theManualWarnsAtTheCLIRecord() {
        let core = AgentManual.core(pathLine: AgentManual.pathLine(quoted: Self.longPath))
        #expect(Self.recordLines(in: core).count == 1, "the core has no CLI record line")
        // A take with no --playhead starts at frame 0 and replaces the clips under it (code gate 1 item 2).
        let line = Self.recordLines(in: core).first ?? ""
        #expect(line.contains("--playhead <frame>") && line.contains("replaces the clips under it"), "\(line)")
        for text in [AgentManual.manual(pathLine: "x"), AgentManual.skill] + AgentManual.recipes.map(\.steps) {
            let bare = Self.recordLines(in: text).filter { !Self.warns($0) }
            #expect(bare.isEmpty, "a CLI record line with no warning: \(bare)")
        }
        // The negative control: the example with no warning is found.
        let fixture = "- `dirigible record <package> --seconds 10 --arm host` records a take."
        #expect(Self.recordLines(in: fixture).count == 1 && !Self.warns(fixture))
    }

    @Test func theRecipesHaveKebabNames() {
        let names = AgentManual.recipes.map(\.name)
        #expect(
            names == [
                "prepare-tracks", "cut-a-range", "cut-from-transcript", "check-levels", "add-sound", "lower-music",
                "add-chapter",
                "prepare-for-publishing",
            ])
        for recipe in AgentManual.recipes {
            #expect(recipe.name.wholeMatch(of: /[a-z]+(-[a-z]+)*/) != nil, "\(recipe.name) is not kebab-case")
            #expect(!recipe.title.isEmpty && !recipe.summary.isEmpty && !recipe.steps.isEmpty, "\(recipe.name)")
        }
    }

    static var core: String { AgentManual.core(pathLine: AgentManual.pathLine(quoted: longPath)) }

    /// The recipe of `name`, or an empty one.
    static func steps(_ name: String) -> String { AgentManual.recipes.first { $0.name == name }?.steps ?? "" }

    /// W7: the core gives the phases in the order of the work, each with its rule and its recipes,
    /// and the recipes, the prompts, and the skill follow that order.
    @Test func thePhasesAreInOrder() {
        let lines = Self.core.split(separator: "\n").map(String.init)
        let start = lines.firstIndex(of: "Phases and recipes, in order:")
        #expect(start != nil, "the core has no phase block")
        let phases = Array(lines.dropFirst((start ?? lines.count) + 1).prefix(5))
        #expect(
            phases.map { $0.prefix { $0 != ":" } } == ["- Prepare", "- Record", "- Edit", "- Produce", "- Export"],
            "\(phases)")
        let order = AgentManual.Phase.allCases
        let indices = AgentManual.recipes.map { order.firstIndex(of: $0.phase) ?? -1 }
        #expect(indices == indices.sorted(), "the recipes are not in phase order")
        for (phase, line) in zip(order, phases) {
            for recipe in AgentManual.recipes where line.contains(recipe.name) != (recipe.phase == phase) {
                Issue.record("\(recipe.name) is not on the line of its phase only: \(line)")
            }
        }
        let record = phases.first { $0.hasPrefix("- Record:") } ?? ""
        #expect(Self.recordLines(in: record).count == 1, "the Record line has no CLI record rule: \(record)")
        #expect(!AgentManual.recipes.contains { $0.phase == .record }, "the record phase has a recipe")
        let skill = AgentManual.skill
        let titles = order.compactMap { skill.range(of: "\n### \($0.title)\n")?.lowerBound }
        #expect(titles.count == order.count && titles == titles.sorted(), "the skill has no phase sections in order")
    }

    /// Decision 0062: the time rule names the tools that read audio by time. RR11: a cut gives all
    /// its ranges in one call.
    @Test func theTimeRuleNamesTheReads() {
        #expect(!Self.core.contains("ask the user for the frame") && !Self.core.contains("No tool reads the audio"))
        let time = Self.core.split(separator: "\n").first { $0.hasPrefix("- Times are frames") } ?? ""
        #expect(
            time.contains("frame = seconds x sample rate, rounded")
                && time.contains("`silences`, `nearest_pause`, and `meter` read audio by time."), "\(time)")
        let ripple = Self.core.split(separator: "\n").first { $0.hasPrefix("- The ripple tools") } ?? ""
        #expect(ripple.contains("Give all the ranges of a cut in one call."), "\(ripple)")
        #expect(!ripple.contains("from the last range"), "\(ripple)")
    }

    /// The busy text of a dialog asks the user, and the other busy texts say to try again. The
    /// rule has one branch for each: the agent asks and waits for the user, or it tries again
    /// after a few seconds. A retry timer alone would use the 3 tries before the user answers.
    @Test func theBusyRuleFollowsTheStepOfTheText() {
        let rule = Self.core.split(separator: "\n").first { $0.contains("\"is busy in Dirigible\"") } ?? ""
        #expect(rule.contains("if the text asks the user, ask and wait."), "\(rule)")
        #expect(rule.contains("Else try again after a few seconds, at most 3 times."), "\(rule)")
    }

    /// W8 and RR11: the transcript is of the current session with each track heard, the user
    /// agrees before the cut, and one call cuts all the words, so the recipe has no merge and no
    /// order. A cut ripples each track, so a track that the export left out stops the recipe (code
    /// gate 1 item 1). Run transcript-1 T18: the transcript tools replace the frame math, `path`
    /// goes first, and the recipe states the limit of the import track. The range recipe says that
    /// `from` and `to` are arrays.
    @Test func theTranscriptRecipeCutsInOneCall() {
        let steps = Self.steps("cut-from-transcript")
        for text in [
            "of the current session from frame 0 with each track heard", "muted or not soloed, stop and ask the user",
            "or of one take: give `take`", "Many skipped words mean a wrong `take`",
            "`transcript_import` with the `path`",
            "`text` only for a short transcript", "`transcript_words` with `match`",
            "words follow the clips of the import track: edit all tracks together", "before the cut",
            "one `transcript_cut` with all the occurrences", "run `transcript_words` again before the next cut",
        ] {
            #expect(steps.contains(text), "the transcript recipe does not say \(text)")
        }
        for text in ["merge", "from the last range", "for each range", "clip_ripple_delete", "sample rate"] {
            #expect(!steps.contains(text), "the transcript recipe still says \(text)")
        }
        #expect(Self.steps("cut-a-range").contains("`from` and `to` are arrays"), "the range recipe")
    }

    /// The `record` text, or "" when the tool is missing.
    static var recordText: (tool: String, seconds: String) {
        let tool = Tool.all.first { $0.name == "record" }
        let schema = tool?.listing["inputSchema"] as? [String: Any]
        let seconds = (schema?["properties"] as? [String: Any])?["seconds"] as? [String: Any]
        return (tool?.description ?? "", seconds?["description"] as? String ?? "")
    }

    /// C1: an agent take stops at its `seconds`, so the `record` text and its `seconds` ask for a
    /// length past the planned end of a live talk.
    @Test func theRecordRuleAsksForALengthPastThePlan() {
        let rule = "For a live talk, ask for a length well past the planned end, for example the plan plus 1 hour"
        #expect(Self.recordText.tool.contains(rule), "the record text")
        #expect(Self.recordText.seconds.contains(rule), "the seconds text")
    }

    /// W1: a transcript with no word times gives cues, and a cut removes each whole cue.
    @Test func theTranscriptRecipeStopsAtCues() {
        let steps = Self.steps("cut-from-transcript")
        #expect(steps.contains("Turn on word timestamps (Whisper)"), "word times")
        #expect(
            steps.contains(
                "When `transcript_import` reports cues, stop and ask the user: a cut removes each whole cue"),
            "cues")
    }

    /// N5: two imports of one transcript on two tracks break each cut into single words.
    @Test func theTranscriptRecipeImportsOnce() {
        #expect(Self.steps("cut-from-transcript").contains("Import the transcript once, on one track"))
    }

    /// W3: a silent call track is invisible to the agent, so after a take the agent reads the
    /// loudness of the new clips, in the `record` text and in the transcript recipe. A near-silent
    /// track gives a value far below the others, not "none".
    @Test func theRecordRuleChecksTheTakeLoudness() {
        let rule =
            "After a take, run `loudness`: \"none\" for a clip, or a value far below the other tracks (below -50 "
            + "LUFS), means that its track got almost no sound; tell the user"
        #expect(Self.recordText.tool.contains(rule), "the record text")
        #expect(Self.steps("cut-from-transcript").contains(rule), "the transcript recipe")
    }

    /// W9: the recipe of the tracks names the source tools, and the sound recipe imports at a frame.
    @Test func thePrepareAndSoundRecipesNameTheirTools() {
        let prepare = Self.steps("prepare-tracks")
        for tool in ["devices", "apps", "track_add", "track_route", "track_add_call"] {
            #expect(prepare.contains("`\(tool)`"), "prepare-tracks does not name \(tool)")
        }
        let sound = Self.steps("add-sound")
        #expect(sound.contains("`import` with `file` (an absolute path), `track`, and `at` (a frame)"), "\(sound)")
        #expect(sound.contains("a new track from `track_add`") && sound.contains("a track that has no clip"))
        // Import folds a stereo file on a mono track (code gate 1, Consider).
        #expect(sound.contains("`track_add` with the layout of the file"), "\(sound)")
    }

    /// The sound recipe shapes the clip in one `import`, with no `clip_gain`. Each import
    /// converts the whole source, so more parts of one file come from
    /// `clip_place` with the file ID and `clip_fade`.
    @Test func theSoundRecipeShapesTheClipInOneImport() {
        let sound = Self.steps("add-sound")
        for argument in ["offset", "length", "db", "fade_in", "fade_out"] {
            #expect(sound.contains("`\(argument)`"), "add-sound does not name \(argument)")
        }
        #expect(!sound.contains("clip_gain"), "\(sound)")
        #expect(sound.contains("`clip_place` with the file ID") && sound.contains("`clip_fade`"), "\(sound)")
        #expect(!sound.contains("again reuses"), "\(sound)")
    }

    /// A heal after a cut joins only the splits that stay, and the words need a new read.
    @Test func theCutRecipeHealsOnlyTheSplitsThatStay() {
        let cut = Self.steps("cut-a-range")
        for text in [
            "`clip_heal` joins the splits that stay after the cuts", "\"no join to heal\" is normal",
            "a cut leaves a gap in the file", "run `transcript_words` again",
        ] {
            #expect(cut.contains(text), "cut-a-range does not say \(text)")
        }
    }

    /// A chapters file keeps each image at its time, and a chapter whose image
    /// the file leaves out is removed first.
    @Test func theChapterRecipeImportsAFileAndKeepsTheImages() {
        let chapter = Self.steps("add-chapter")
        for text in [
            "`chapters_import` with `path`", "each image stays on the chapter of the file at the same time",
            "run `marker_remove` for it first",
        ] {
            #expect(chapter.contains(text), "add-chapter does not say \(text)")
        }
    }

    /// The publish recipe writes the chapter list, and lists the unused files by the tool on a
    /// closed package and by the menu in the app (the tool is refused there).
    @Test func thePublishRecipeListsTheChaptersAndTheUnusedFiles() {
        let publish = Self.steps("prepare-for-publishing")
        for text in [
            "`chapters_export` with `out` a .txt file", "`file_prune` with `dry_run`", "File > Remove Unused Files",
        ] {
            #expect(publish.contains(text), "prepare-for-publishing does not say \(text)")
        }
    }

    /// The reading lines of the recipes name `session_info` with `compact`.
    @Test func theReadingLinesUseCompact() {
        for name in ["cut-a-range", "prepare-for-publishing"] {
            #expect(Self.steps(name).contains("`session_info` (use `compact`)"), "\(name)")
        }
    }

    /// W9: each import at a frame warns that the clip replaces the clips under it.
    @Test func theImportSaysItReplaces() {
        let texts = [AgentManual.manual(pathLine: "x"), AgentManual.skill] + AgentManual.recipes.map(\.steps)
        let lines = texts.flatMap(Self.importLines)
        #expect(!lines.isEmpty, "no import line")
        #expect(
            lines.allSatisfy(Self.warnsAtImport),
            "an import line with no warning: \(lines.filter { !Self.warnsAtImport($0) })")
        // The negative control: the example with no warning is found.
        let fixture = "- add-sound: `import` with `file`, `track`, and `at`."
        #expect(Self.importLines(in: fixture).count == 1 && !Self.warnsAtImport(fixture))
    }

    /// W10: the manual says what does not exist yet, until a tool or a command for it exists.
    @Test func theManualSaysWhatDoesNotExist() {
        #expect(Self.core.contains("Dirigible has no noise reduction and no voice profile yet: tell the user."))
        // The words of the span scan hold each tool name, argument, and command word.
        #expect(
            Self.notYetNames(ManualScan.words.sorted()).isEmpty,
            "A noise or voice feature exists: change the not-yet line of AgentManual.core and of docs/guide.md")
        // The control: a fixture name list with a denoise tool is found.
        #expect(Self.notYetNames(["clip_gain", "clip_denoise"]) == ["clip_denoise"])
    }

    /// W11: the recipes name the tools of run 7b, not their commands.
    @Test func theRecipesUseTheLongTools() {
        for name in ["check-levels", "prepare-for-publishing"] {
            let steps = Self.steps(name)
            #expect(steps.contains("`loudness`") && steps.contains("`level`"), "\(name) does not name its tools")
        }
        for recipe in AgentManual.recipes {
            let bad = ManualScan.commandLines(in: recipe.steps).filter { line in
                ["loudness", "export", "level", "import"].contains { line.hasPrefix("dirigible \($0)") }
            }
            #expect(bad.isEmpty, "\(recipe.name): \(bad)")
        }
        #expect(Self.steps("prepare-for-publishing").contains("`export`"))
        #expect(Self.steps("add-sound").contains("`import`"))
    }

    /// The lines that import at a frame: the `import` tool with `at`, or `dirigible import` with `--at`.
    static func importLines(in text: String) -> [String] {
        text.split(separator: "\n").map(String.init).filter { line in
            (line.contains("`import`") && line.contains("`at`"))
                || ManualScan.commandLines(in: line).contains {
                    $0.hasPrefix("dirigible import ") && $0.contains("--at")
                }
        }
    }

    static func warnsAtImport(_ line: String) -> Bool { line.contains("replaces the clips under it") }

    /// The names of a noise reduction or voice profile feature.
    static func notYetNames(_ names: [String]) -> [String] {
        names.filter { name in ["noise", "denoise", "voice"].contains { name.contains($0) } }
    }

    /// The lines that have a `dirigible record ...` span.
    static func recordLines(in text: String) -> [String] {
        text.split(separator: "\n").map(String.init).filter { line in
            ManualScan.commandLines(in: line).contains { $0.hasPrefix("dirigible record ") }
        }
    }

    static func warns(_ line: String) -> Bool {
        line.contains("with no consent sheet") && line.contains("only when the user asked for a recording")
            && line.contains("`record` tool")
    }
}
