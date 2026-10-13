import ArgumentParser
import Foundation

@testable import DirigibleCLI
@testable import DirigibleMCP

/// The span scan of the agent manual (decision 0051, C5). Each backticked span gets a class from
/// the data: a `name(arg, ...)` call of a tool with arguments of its schema; one lowercase or
/// snake_case word that is a tool, a tool argument, an `enum` value of a tool schema, or a
/// `dirigible` command word; or a `dirigible ...` command line, which
/// `AgentManualCommandTests.eachCommandExampleParses` parses. Other spans (paths, menu names) are
/// not words of this grammar.
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
            let keys = Set(tool.params.map(\.key) + ["package"])
            return call.2.split(separator: ",").allSatisfy {
                keys.contains($0.trimmingCharacters(in: .whitespaces))
            }
        }
        guard span.wholeMatch(of: /[a-z][a-z0-9_]*/) != nil else { return true }
        return words.contains(span)
    }

    /// The tools, their argument names, the `enum` values of their schemas, and each command word.
    static let words: Set<String> = {
        var words = Set(Tool.all.map(\.name)).union(["package"])
        for param in Tool.all.flatMap(\.params) {
            words.insert(param.key)
            words.formUnion(param.schema["enum"] as? [String] ?? [])
        }
        return words.union(commandWords(of: Dirigible.self))
    }()

    private static func commandWords(of command: any ParsableCommand.Type) -> Set<String> {
        command.configuration.subcommands.reduce(into: [command._commandName]) { $0.formUnion(commandWords(of: $1)) }
    }
}
