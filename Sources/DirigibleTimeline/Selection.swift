import DirigibleCore
import Foundation

/// The selection of a window (decision 0038): a range (in, out, tracks) or a set of clips. The two
/// kinds are never active together. Window state in `SessionWindow`, never in `Session`.
public enum Selection: Hashable, Sendable {
    /// `.range(Marks())` is no selection.
    case range(Marks)
    /// The clips of Command-click.
    case clips(ClipSet)

    public static let none = Selection.range(Marks())

    /// The range; nil for a clip set, so a range edit does nothing for it.
    public var marks: Marks? {
        if case .range(let marks) = self { return marks }
        return nil
    }
}

/// The clips of a clip selection: never empty. An ID that an undo removed stays until the next read
/// drops it.
public struct ClipSet: Hashable, Sendable {
    public let ids: Set<ClipID>

    /// Nil when `ids` is empty.
    public init?(_ ids: Set<ClipID>) {
        guard !ids.isEmpty else { return nil }
        self.ids = ids
    }
}
