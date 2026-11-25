import ArgumentParser
import Foundation

@testable import DirigibleCLI
@testable import DirigibleMCP

/// The span scan of the agent manual (decision 0051, C5). Each backticked span gets a class from
/// the data: a `name(arg, ...)` call of a tool with arguments of its schema; one lowercase or
/// snake_case word that is a tool, a tool argument, an `enum` value of a tool schema, or a
/// `dirigible` command word; or an option such as `--pre-roll <seconds>`, which a command lists in
/// its help; or a `dirigible ...` command line, which
/// `AgentManualCommandTests.eachCommandExampleParses` parses; or a name of a tool output that
/// the manual lists (`outputNames`); or a path, the `realpath` form of the
/// skill, a recipe name, or a prompt name such as `/dirigible:check-levels`. Each other span fails.
enum ManualScan {
    /// The text between each pair of backticks on one line.
    static func spans(in text: String) -> [String] { text.matches(of: /`([^`\n]+)`/).map { String($0.1) } }

    /// The spans that start with the command name, for example `dirigible level <package>`.
    static func commandLines(in text: String) -> [String] { spans(in: text).filter { $0.hasPrefix("dirigible ") } }

    /// The spans of `text` that have no class.
    static func spansWithNoClass(in text: String) -> [String] {
        spans(in: text).filter { !hasClass($0) }
    }

    private static func hasClass(_ span: String) -> Bool {
        if span.hasPrefix("dirigible ") { return true }
        if let call = span.wholeMatch(of: /([a-z_]+)\((.*)\)/) {
            guard let tool = Tool.all.first(where: { $0.name == call.1 }) else { return false }
            let keys: Set<String> =
                switch tool.body {
                case .package(let params, _): Set(params.map(\.key) + ["package"])
                case .local: []
                }
            return call.2.split(separator: ",").allSatisfy {
                keys.contains($0.trimmingCharacters(in: .whitespaces))
            }
        }
        if outputNames.contains(span) { return true }
        if span.wholeMatch(of: /[a-z][a-z0-9_]*/) != nil { return words.contains(span) }
        if let option = span.wholeMatch(of: /(--[a-z][a-z0-9-]*)(?: <[^>]+>)?/) {
            return options.contains(String(option.1))
        }
        let recipes = AgentManual.recipes.map(\.name)
        let path = span.contains("/") && !span.contains(" ") && !span.contains(":")
        return path || span.hasPrefix("realpath ") || recipes.contains(span)
            || recipes.contains { span == "dirigible:\($0)" || span == "/dirigible:\($0)" }
    }

    /// The key and the line of the `info` output that the manual names (decision 0071), and the
    /// marker lines of the `import_session` reply (decision 0075), and the label of the `archive:` line
    /// of `info` (decision 0072).
    static let outputNames: Set<String> = [
        "rawKept", "raw <stem> kept: <reason>", "marker <id>", "Left out:", "archive:",
    ]

    /// The tools, their argument names, the `enum` values of their schemas, and each command word.
    static let words: Set<String> = {
        var words = Set(Tool.all.map(\.name)).union(["package"])
        for param in Tool.all.flatMap(\.params) {
            words.insert(param.key)
            words.formUnion(param.schema["enum"] as? [String] ?? [])
        }
        return words.union(commandWords(of: Dirigible.self))
    }()

    /// The long options that the help text of each command lists.
    static let options: Set<String> = {
        func options(of command: any ParsableCommand.Type) -> Set<String> {
            let help = command.helpMessage(columns: 200)
            let own = Set(help.matches(of: /(?:^|[^\w-])(--[a-z][a-z0-9-]*)/).map { String($0.1) })
            return command.configuration.subcommands.reduce(own) { $0.union(options(of: $1)) }
        }
        return options(of: Dirigible.self)
    }()

    private static func commandWords(of command: any ParsableCommand.Type) -> Set<String> {
        command.configuration.subcommands.reduce(into: [command._commandName]) { $0.formUnion(commandWords(of: $1)) }
    }
}
