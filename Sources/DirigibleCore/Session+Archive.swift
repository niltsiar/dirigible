import Foundation

/// "<stem>.flac" for a pool path that ends in ".wav" (any case), else nil: the archive converts
/// only WAV clip files (decision 0072).
public func archivedPath(of path: String) -> String? {
    guard path.lowercased().hasSuffix(".wav") else { return nil }
    return String(path.dropLast(4)) + ".flac"
}

/// The name in the folder of `name` of the file that an archive job writes for `name` until its
/// rename: ".<name>.archive-<UUID>.tmp".
package func archiveTemporaryName(of name: String, _ uuid: UUID) -> String { ".\(name).archive-\(uuid.uuidString).tmp" }

/// True for a name that `archiveTemporaryName(of:_:)` gives. `removeTemporaryFiles` deletes such a file.
package func isArchiveTemporary(_ name: String) -> Bool {
    guard let match = name.wholeMatch(of: /\.(.+)\.archive-([^.]+)\.tmp/), let uuid = UUID(uuidString: String(match.2))
    else { return false }
    return name == archiveTemporaryName(of: String(match.1), uuid)
}
