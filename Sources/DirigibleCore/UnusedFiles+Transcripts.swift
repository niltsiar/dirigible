import Foundation

extension UnusedFiles {
    /// Each regular file `<canonical UUID>.xml` in `Transcripts/` of `package`, as an item. A
    /// missing folder gives none; a link or another read error throws, so an error never reads as
    /// no file.
    static func transcriptItems(in package: URL) throws(UnusedFilesError) -> [Item] {
        let folder = package.appending(path: transcriptsFolderName)
        var folderInfo = stat()
        guard lstat(folder.path, &folderInfo) == 0 else {
            guard errno == ENOENT else { throw .transcriptsUnreadable(errno: errno) }
            return []
        }
        guard folderInfo.st_mode & S_IFMT == S_IFDIR else { throw .transcriptsUnreadable(errno: ENOTDIR) }
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        } catch {
            throw .transcriptsUnreadable(errno: posixCode(of: error))
        }
        let real = package.resolvingSymlinksInPath().appending(path: transcriptsFolderName).path
        return names.compactMap { name in
            let url = folder.appending(path: name)
            var info = stat()
            guard name.hasSuffix(".xml"), let file = TranscriptFileName(String(name.dropLast(4))),
                staysIn(real, url), lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG
            else { return nil }
            return Item(
                kind: .transcript(file), path: "\(transcriptsFolderName)/\(name)", bytes: Int64(info.st_size),
                identity: FileIdentity(info))
        }
    }
}
