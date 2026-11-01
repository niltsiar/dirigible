import DirigibleCore

/// The argument rules and the lines of `dirigible silence-edit` and the tool `silence_edit`
/// (decision 0066). The command and the tool both build the plan here, before they read the
/// session, and both print the lines of `lines(_:)`.
package struct SilenceEditWork: Sendable {
    /// Why the arguments make no plan. `pair` is the 1-based number of the pair, or nil when the
    /// call has one pair.
    package enum Refusal: Error, Equatable {
        case missing
        case unpaired
        case unknownAction(String, pair: Int?)
        case notOrdered(pair: Int?)
        case outOfRange(pair: Int?)
        case overlap(pair: Int?)
        case keepOutOfRange

        /// The text of the refusal. `prefix` goes before each argument name: `--` for the command,
        /// nothing for the tool.
        package func message(prefix: String) -> String {
            let (from, to, action) = ("\(prefix)from", "\(prefix)to", "\(prefix)action")
            func named(_ text: String, _ pair: Int?) -> String { pair.map { "\(text) (pair \($0))." } ?? "\(text)." }
            switch self {
            case .missing: return "Give one or more \(from), \(to), and \(action)."
            case .unpaired: return "Give one \(to) and one \(action) for each \(from)."
            case .unknownAction(let word, let pair):
                return named("\(action) must be shorten, mute, or mark, not \"\(word)\"", pair)
            case .notOrdered(let pair): return named("\(from) must not be more than \(to)", pair)
            case .outOfRange(let pair): return named("A frame must be 0 to 2^40", pair)
            case .overlap(let pair): return named("The ranges must not overlap", pair)
            case .keepOutOfRange: return "\(prefix)keep must be 0 to 2^40."
            }
        }
    }

    package let plan: SilencePlan

    /// The pairs of `from`, `to`, and `actions`, in order. A mark is named "Silence N" by its
    /// number among the mark pairs.
    package init(from: [Int], to: [Int], actions: [String], keep: Int?) throws(Refusal) {
        guard !(from.isEmpty && to.isEmpty && actions.isEmpty) else { throw .missing }
        guard from.count == to.count, from.count == actions.count else { throw .unpaired }
        let several = from.count > 1
        func named(_ number: Int) -> Int? { several ? number : nil }
        var edits: [SilenceEdit] = []
        var marks = 0
        for index in from.indices {
            let pair = named(index + 1)
            let action: SilenceEdit.Action
            switch actions[index] {
            case "shorten": action = .shorten
            case "mute": action = .mute
            case "mark":
                marks += 1
                action = .mark(name: "Silence \(marks)")
            default: throw .unknownAction(actions[index], pair: pair)
            }
            guard let range = EditRules.frameRange(from: from[index], to: to[index]) else {
                throw .notOrdered(pair: pair)
            }
            edits.append(SilenceEdit(range: range, action: action))
        }
        do throws(SilencePlan.Refusal) {
            plan = try SilencePlan(edits, keep: keep.map { Frames($0) })
        } catch {
            switch error {
            case .outOfRange(let number): throw .outOfRange(pair: named(number))
            case .overlap(let number): throw .overlap(pair: named(number))
            case .keepOutOfRange: throw .keepOutOfRange
            }
        }
    }

    /// One line for each pair, in plan order, then the frames removed. The frames are those of
    /// the session before the edit.
    package func lines(_ result: SilenceResult) -> [String] {
        let skipped = Set(result.skipped)
        var (cuts, markers) = (result.cuts.makeIterator(), result.markers.makeIterator())
        var lines: [String] = []
        for (index, edit) in plan.edits.enumerated() {
            let range = "\(edit.range.lowerBound)\t\(edit.range.upperBound)"
            if skipped.contains(index + 1) {
                lines.append("skipped\t\(range)\t\(edit.action.word)")
                continue
            }
            switch edit.action {
            case .shorten:
                let cut = cuts.next()!
                lines.append("shorten\t\(range)\t\(cut.lowerBound)\t\(cut.upperBound)")
            case .mute: lines.append("mute\t\(range)")
            case .mark: lines.append("mark\t\(range)\t\(markers.next()!.rawValue)")
            }
        }
        lines.append("removed \(result.removed) frames")
        return lines
    }
}

extension SilenceEdit.Action {
    fileprivate var word: String {
        switch self {
        case .shorten: "shorten"
        case .mute: "mute"
        case .mark: "mark"
        }
    }
}
