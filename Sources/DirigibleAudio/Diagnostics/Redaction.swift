import Darwin
import Foundation
import SystemConfiguration

/// The names of this Mac and of its user that a report must not hold (decision 0059).
struct Redaction: Sendable {
    /// One private value and its replacement. A `wholeWord` rule matches only between characters
    /// that are not a letter, a digit, or `_`. Each match ignores case.
    struct Rule: Sendable, Equatable {
        let value: String
        let replacement: String
        let wholeWord: Bool
    }

    let rules: [Rule]

    /// The home folder becomes `~`; the short name, the full name, and each word of the full name
    /// become `USER`; the computer name becomes `MAC-NAME`; and each host name becomes
    /// `HOST-NAME`. A value of 3 characters or fewer, and a word of the full name, match only as a
    /// whole word, so a user "Mark" keeps `marker_set`. A word of 1 character is kept.
    init(home: String, user: String, fullName: String, computer: String?, hosts: [String]) {
        func rule(_ value: String, _ replacement: String, wholeWord: Bool = false) -> Rule {
            Rule(value: value, replacement: replacement, wholeWord: wholeWord || value.count <= 3)
        }
        let words = fullName.split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 1 }
        var rules = [rule(home, "~"), rule(user, "USER"), rule(fullName, "USER")]
        rules += words.map { rule($0, "USER", wholeWord: true) }
        rules += [computer].compactMap { $0 }.map { rule($0, "MAC-NAME") }
        rules += hosts.filter { $0.lowercased() != "localhost" }.map { rule($0, "HOST-NAME") }
        self.init(rules: rules)
    }

    init(rules: [Rule]) {
        var seen: Set<String> = []
        self.rules = rules.filter { !$0.value.isEmpty && seen.insert($0.value.lowercased()).inserted }
    }

    /// The values of this Mac. The host names come from the system configuration and
    /// `gethostname`, with no DNS lookup.
    static func live() -> Redaction {
        var hosts = [SCDynamicStoreCopyLocalHostName(nil) as String?].compactMap { $0 }
        var buffer = [CChar](repeating: 0, count: Int(MAXHOSTNAMELEN) + 1)
        if gethostname(&buffer, buffer.count - 1) == 0 {
            let name = String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
            hosts += [name, String(name.prefix { $0 != "." })]
        }
        return Redaction(
            home: NSHomeDirectory(), user: NSUserName(), fullName: NSFullUserName(),
            computer: SCDynamicStoreCopyComputerName(nil, nil) as String?, hosts: hosts)
    }

    /// `text` with each match replaced, in one scan: at each place the longest value wins, and a
    /// replacement is not scanned again.
    func apply(_ text: String) -> String {
        let ordered = rules.sorted { $0.value.count > $1.value.count }
        guard !ordered.isEmpty else { return text }
        let word = "[\\p{L}\\p{N}_]"
        let pattern = ordered.map { rule in
            let value = NSRegularExpression.escapedPattern(for: rule.value)
            return rule.wholeWord ? "(?<!\(word))(\(value))(?!\(word))" : "(\(value))"
        }.joined(separator: "|")
        // The pattern holds only escaped literals, so it always compiles.
        let expression = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        let source = text as NSString
        var out = ""
        var end = 0
        for match in expression.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            guard let group = (1...ordered.count).first(where: { match.range(at: $0).location != NSNotFound })
            else { continue }
            out += source.substring(with: NSRange(location: end, length: match.range.location - end))
            out += ordered[group - 1].replacement
            end = match.range.location + match.range.length
        }
        return out + source.substring(from: end)
    }
}
