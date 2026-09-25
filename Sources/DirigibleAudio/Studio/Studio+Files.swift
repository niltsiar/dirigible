import DirigibleCore
import Foundation

extension Studio {
    /// The URLs of the pool files in `files` that are on disk, sorted by path, under the package
    /// path that the lock holds now (decision 0014), not a stored copy. It reads the disk off the
    /// main actor and writes nothing. An ID that is not in the pool gives nothing.
    public func clipURLs(_ files: Set<FileID>) async -> [URL] {
        await existingClipURLs(files.compactMap { session.files[$0]?.path }, lock: lock)
    }
}

@concurrent nonisolated private func existingClipURLs(_ paths: [String], lock: PackageLock) async -> [URL] {
    dispatchPrecondition(condition: .notOnQueue(.main))
    guard let package = try? lock.package() else { return [] }
    let clips = package.appending(path: clipsFolderName)
    return paths.sorted().map { clips.appending(path: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
}
