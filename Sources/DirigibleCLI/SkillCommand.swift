import ArgumentParser
import DirigibleMCP
import Foundation

/// `dirigible skill`: the skill of the agent manual (decision 0051). It reads no package.
struct SkillCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "skill", abstract: "Give the agent skill of Dirigible.", subcommands: [Show.self, Path.self])

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print the SKILL.md text of the agent skill.")

        func run() { print(AgentManual.skill, terminator: "") }
    }

    struct Path: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print the path of the SKILL.md file in the app that holds this tool.",
            discussion: "Exit 1 when no app holds this tool, or the app has no skill file.")

        func run() throws {
            let skill = Bundle.main.executableURL.flatMap(appContents(of:))?
                .appending(path: "Resources/skills/dirigible/SKILL.md")
            guard let skill, FileManager.default.fileExists(atPath: skill.path) else {
                throw fail(
                    "no app with a skill file holds this dirigible. Run `dirigible skill show` for the skill text.",
                    code: ExitCode.failure.rawValue)
            }
            print(skill.path)
        }
    }
}
