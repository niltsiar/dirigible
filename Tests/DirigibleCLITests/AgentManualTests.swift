import Foundation
import Testing

@testable import DirigibleMCP

/// The text of the agent manual (decision 0051): its length, its CLI path, its record warning,
/// and its recipes.
struct AgentManualTests {
    /// A quoted path of 202 characters, longer than a real install path.
    static let longPath = "'/" + String(repeating: "a", count: 199) + "'"

    /// The documented cut of Claude Code is 2048 characters (C4).
    static func fitsTheClientLimits(core: String, whole: String) -> Bool { core.count <= 2048 && whole.count <= 4000 }

    @Test func theCoreFitsTheClientLimit() {
        let pathLine = AgentManual.pathLine(quoted: Self.longPath)
        let core = AgentManual.core(pathLine: pathLine)
        let whole = AgentManual.manual(pathLine: pathLine)
        #expect(Self.fitsTheClientLimits(core: core, whole: whole), "core \(core.count), whole \(whole.count)")
        #expect(whole.hasPrefix(core) && core.contains("For work with no tool"), "the no-tool rule is in the core")
        // The boundary pair of the limit.
        let text = { (count: Int) in String(repeating: "x", count: count) }
        #expect(Self.fitsTheClientLimits(core: text(2048), whole: text(4000)))
        #expect(!Self.fitsTheClientLimits(core: text(2049), whole: text(4000)))
        #expect(!Self.fitsTheClientLimits(core: text(2048), whole: text(4001)))
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
                "prepare-tracks", "cut-a-range", "cut-from-transcript", "check-levels", "add-sound", "add-chapter",
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

    /// W8: frames come from the user or from a transcript, and a cut goes from the last range.
    @Test func theTimeRuleAllowsATranscript() {
        #expect(!Self.core.contains("ask the user for the frame"))
        let time = Self.core.split(separator: "\n").first { $0.hasPrefix("- Times are frames") } ?? ""
        #expect(
            time.contains("frame = seconds x sample rate, rounded") && time.contains("from a transcript"), "\(time)")
        let ripple = Self.core.split(separator: "\n").first { $0.hasPrefix("- The ripple tools") } ?? ""
        #expect(ripple.contains("Cut from the last range to the first."), "\(ripple)")
    }

    /// W8: the transcript is of the current session, the ranges merge, the user agrees before the
    /// first cut, and the cuts go from the last range to the first.
    @Test func theTranscriptRecipeCutsFromTheLast() {
        let steps = Self.steps("cut-from-transcript")
        for text in [
            "of the current session from frame 0", "merge ranges that overlap", "the sample rate of `session_info`",
            "before the first cut", "`clip_ripple_delete` with no `track`", "from the last range to the first",
        ] {
            #expect(steps.contains(text), "the transcript recipe does not say \(text)")
        }
    }

    /// W9: the recipe of the tracks names the source tools, and the sound recipe imports at a frame.
    @Test func thePrepareAndSoundRecipesNameTheirTools() {
        let prepare = Self.steps("prepare-tracks")
        for tool in ["devices", "apps", "track_add", "track_route", "track_add_call"] {
            #expect(prepare.contains("`\(tool)`"), "prepare-tracks does not name \(tool)")
        }
        let sound = Self.steps("add-sound")
        #expect(sound.contains("`dirigible import <package> <audio file> --track <track ID> --at <frame>`"), "\(sound)")
        #expect(sound.contains("a new track from `track_add`") && sound.contains("a track that has no clip"))
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
        let fixture = "- add-sound: `dirigible import <package> <audio file> --track <track ID> --at <frame>`."
        #expect(Self.importLines(in: fixture).count == 1 && !Self.warnsAtImport(fixture))
    }

    /// W10: the manual says what does not exist yet, until a tool or a command for it exists.
    @Test func theManualSaysWhatDoesNotExist() {
        #expect(Self.core.contains("Dirigible has no noise reduction and no voice profile yet: tell the user."))
        let names = Tool.all.map(\.name) + ManualScan.words.sorted()
        #expect(
            Self.notYetNames(names).isEmpty,
            "A noise or voice feature exists: change the not-yet line of AgentManual.core and of docs/guide.md")
        // The control: a fixture name list with a denoise tool is found.
        #expect(Self.notYetNames(["clip_gain", "clip_denoise"]) == ["clip_denoise"])
    }

    /// W11: the recipes name the tools of run 7b, not their commands.
    @Test func theRecipesUseTheLongTools() {
        for name in ["check-levels", "prepare-for-publishing"] {
            let steps = Self.steps(name)
            #expect(steps.contains("`loudness`"), "\(name) does not name the loudness tool")
            let bad = ManualScan.commandLines(in: steps).filter {
                $0.hasPrefix("dirigible loudness") || $0.hasPrefix("dirigible export")
            }
            #expect(bad.isEmpty, "\(name): \(bad)")
        }
        #expect(Self.steps("prepare-for-publishing").contains("`export`"))
    }

    static func importLines(in text: String) -> [String] {
        text.split(separator: "\n").map(String.init).filter { line in
            ManualScan.commandLines(in: line).contains { $0.hasPrefix("dirigible import ") && $0.contains("--at") }
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
