import Foundation

/// The names and the file identities of the used files of some sessions.
struct Holders {
    var names: Set<String> = []
    var identities: Set<FileIdentity> = []

    /// Many entries name the same paths, so each path gets one `lstat` and one `stat`.
    init(_ paths: [String], in clips: URL) {
        for path in Set(paths) {
            names.insert(normalized(path))
            identities.formUnion(FileIdentity.both(clips.appending(path: path).path))
        }
    }

    /// True when the name or an identity matches: when the two tests disagree, the file stays.
    func hold(_ path: String, _ ids: Set<FileIdentity>) -> Bool {
        names.contains(normalized(path)) || !identities.isDisjoint(with: ids)
    }
}

/// The device and the inode of a file.
struct FileIdentity: Hashable, Sendable {
    let device: dev_t
    let inode: ino_t

    /// Nil when `lstat` fails; `errno` then has the reason.
    init?(lstat path: String) {
        var info = stat()
        guard Darwin.lstat(path, &info) == 0 else { return nil }
        (device, inode) = (info.st_dev, info.st_ino)
    }

    /// The identity of the `info` of a `stat` or an `lstat`.
    init(_ info: stat) {
        (device, inode) = (info.st_dev, info.st_ino)
    }

    /// The `lstat` and the `stat` identity, so a link and its target match. A caller that has the
    /// `lstat` identity gives it, so the path gets only the `stat`.
    static func both(_ path: String, lstat known: FileIdentity? = nil) -> Set<FileIdentity> {
        var result = Set([known ?? FileIdentity(lstat: path)].compactMap(\.self))
        var info = stat()
        if stat(path, &info) == 0 { result.insert(FileIdentity(info)) }
        return result
    }
}
