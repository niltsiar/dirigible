import Foundation

/// The form of the clip files of an archived session (decision 0072): the `archive` attribute of
/// `<session>`.
public enum SessionArchive: String, Hashable, Sendable {
    case flac
}

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

/// The name on disk of a pool file, relative to the package, and its form.
package struct PoolFileName: Hashable, Sendable {
    package enum Form: Hashable, Sendable {
        /// The pool path itself.
        case pool
        /// The FLAC of an archived pool WAV (`archivedPath(of:)`).
        case flac
    }

    package let name: String
    package let form: Form
}

/// The one way from a pool file to its name on disk (decision 0072): "Clips/<path>" when an item is
/// at that name (`lstat`, so a link counts), else "Clips/<stem>.flac" when an item is there, else
/// "Clips/<path>". It opens nothing. Each opener keeps its own open call and link rule, and opens
/// the other name once on ENOENT: a job of another process can convert the file in between.
package func poolFileName(_ file: AudioFile, in package: URL) -> PoolFileName {
    let name = "\(clipsFolderName)/\(file.path)"
    guard let flac = archivedPath(of: file.path).map({ "\(clipsFolderName)/\($0)" }) else {
        return PoolFileName(name: name, form: .pool)
    }
    var info = stat()
    guard lstat(package.appending(path: name).path, &info) != 0, errno == ENOENT,
        lstat(package.appending(path: flac).path, &info) == 0
    else { return PoolFileName(name: name, form: .pool) }
    return PoolFileName(name: flac, form: .flac)
}
