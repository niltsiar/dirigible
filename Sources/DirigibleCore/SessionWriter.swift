import Foundation

public enum SessionFileError: Error, Hashable, Sendable {
    case malformedXML
    case unsupportedVersion(Int)
    case invalidChannelCount(Int)
    case missingAttribute(element: String, attribute: String)
    case invalidValue(element: String, attribute: String)
    /// The file breaks a rule of the model, for example a clip whose file does not exist.
    case invalidSession(SessionError)
    /// The POSIX error code, so the app can tell a missing file (ENOENT) or a full disk (ENOSPC).
    case readFailed(errno: Int32)
    case writeFailed(step: String, errno: Int32)
    /// The written XML does not read back as the same session. The old file stays. This is a
    /// bug in the model, not a user error.
    /// Holds the reader error, or nil when the XML reads back as a different session.
    indirect case wouldNotReadBack(SessionFileError?)
    /// Another holder has the package lock (decision 0012).
    case locked
    /// The package that the lock holds is no longer on its volume: it moved to another volume or
    /// was deleted (decision 0014). Nothing was written.
    case packageMoved
    /// `Session.create` found a file or a folder at the path. Nothing changed.
    case exists
}

/// The POSIX code under a Foundation file error, or EIO when there is none.
func posixCode(of error: any Error) -> Int32 {
    let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
    guard let underlying, underlying.domain == NSPOSIXErrorDomain else { return EIO }
    return Int32(underlying.code)
}

let sessionNamespace = "https://github.com/niltsiar/dirigible/session"
/// The folder of the clip files in a package (decision 0003).
package let clipsFolderName = "Clips"
/// The name in `Clips/` of the WAV of `stem` until its rename. An import and a finalize write it.
package func temporaryWAV(of stem: String) -> String { ".\(stem).wav.tmp" }
/// True for a name that `temporaryWAV(of:)` gives. `removeTemporaryFiles` deletes such a file.
package func isTemporaryWAV(_ name: String) -> Bool { name.hasPrefix(".") && name.hasSuffix(".wav.tmp") }
/// The folder of the episode artwork in a package (decision 0045).
package let artworkFolderName = "Artwork"
/// The name in `Artwork/` of the image of `name` until its rename.
package func temporaryArtwork(of name: ArtworkName) -> String { ".\(name.name).tmp" }
/// The newest `session.xml` version that this build reads (decision 0024). A save writes
/// `Session.fileVersion`.
package let sessionVersion = 8

extension Session {
    /// Writes `session.xml` in the package, and makes the package and its `Clips/` folder if
    /// they do not exist. The old file stays until the new file is complete and on the disk.
    public func write(to package: URL) throws(SessionFileError) {
        let data = try checkedData()
        let isNew = !FileManager.default.fileExists(atPath: package.path)
        do {
            try FileManager.default.createDirectory(
                at: package.appending(path: clipsFolderName), withIntermediateDirectories: true)
        } catch {
            throw .writeFailed(step: "createDirectory", errno: posixCode(of: error))
        }
        try replaceDurably(package.appending(path: "session.xml"), with: data)
        // A new package is an entry in its parent folder, which a power loss can lose too.
        if isNew { try flush(package.deletingLastPathComponent().path) }
    }

    /// Makes a new package with an empty session (decision 0014): `mkdir` of the package, the
    /// write, then a flush of the parent folder. Throws `.exists` when anything is at the path.
    /// A failure after `mkdir` removes the new folder, so the path has a complete package or
    /// nothing.
    public static func create(at package: URL, sampleRate: Int) throws(SessionFileError) {
        guard mkdir(package.path, 0o755) == 0 else { throw errno == EEXIST ? .exists : posixError("mkdir") }
        do throws(SessionFileError) {
            // `write(to:)` flushes the parent only when it makes the package folder.
            try Session(sampleRate: sampleRate).write(to: package)
            if let code = fullFlush(path: package.deletingLastPathComponent().path) {
                throw .writeFailed(step: "flushParent", errno: code)
            }
        } catch {
            try? FileManager.default.removeItem(at: package)
            throw error
        }
    }

    /// The write of a lock holder (decision 0014): writes `session.xml` in the package that `lock`
    /// holds now, which a rename can have moved, and returns that package path. It never makes the
    /// package folder, so a stale path gets no new package. Throws `.packageMoved` when the package
    /// left its volume. Before the replace, it keeps a backup of the old file in `Backups/` when
    /// one is due (decision 0043).
    @discardableResult
    public func write(under lock: PackageLock) throws(SessionFileError) -> URL {
        try write(under: lock, backups: .standard)
    }

    @discardableResult
    package func write(under lock: PackageLock, backups: BackupPolicy) throws(SessionFileError) -> URL {
        let data = try checkedData()
        let package = try lock.package()
        let clips = package.appending(path: clipsFolderName)
        guard mkdir(clips.path, 0o755) == 0 || errno == EEXIST else { throw posixError("createDirectory") }
        // A backup fault never fails the save.
        try? backups.keepIfDue(in: package, newSize: Int64(data.count))
        try replaceDurably(package.appending(path: "session.xml"), with: data)
        return package
    }

    /// The XML of the session. A file that does not read back would lock the user out of the
    /// session, so it throws `.wouldNotReadBack` then.
    func checkedData() throws(SessionFileError) -> Data {
        let data = xmlDocument().xmlData(options: .nodePrettyPrint)
        let readBack: Session
        do throws(SessionFileError) {
            readBack = try Session(xml: data)
        } catch {
            throw .wouldNotReadBack(error)
        }
        guard readBack == self else { throw .wouldNotReadBack(nil) }
        return data
    }

    /// Deletes the leftover temporary files of a crash: the `.session.xml.<UUID>.tmp` files of a
    /// save and of a backup, each `Clips/.<stem>.wav.tmp` of an import or a finalize that no
    /// file of the pool names, and each `Artwork/.<name>.tmp` of an artwork import. Call it only
    /// under the package lock: without the lock it can delete the file of a save, an import, or a
    /// finalize in progress.
    public func removeTemporaryFiles(in package: URL) {
        func names(_ folder: URL) -> [String] {
            (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        }
        for folder in [package, Backup.folder(of: package)] {
            for name in names(folder) where isTemporaryName(name) { unlink(folder.appending(path: name).path) }
        }
        let pool = Set(
            files.values.map { $0.path.split(separator: "/").filter { $0 != "." }.joined(separator: "/").lowercased() })
        let clips = package.appending(path: clipsFolderName)
        for name in names(clips)
        where isTemporaryWAV(name) && !pool.contains(name.lowercased()) {
            unlink(clips.appending(path: name).path)
        }
        let artwork = package.appending(path: artworkFolderName)
        for name in names(artwork) where name.hasPrefix(".") && name.hasSuffix(".tmp") {
            unlink(artwork.appending(path: name).path)
        }
    }

    func xmlDocument() -> XMLDocument {
        let root = element("session", ("version", String(fileVersion)), ("sampleRate", String(sampleRate)))
        let namespace = XMLNode(kind: .namespace)
        namespace.name = ""
        namespace.stringValue = sessionNamespace
        root.addNamespace(namespace)

        let captureList = element("captures")
        for capture in captures.values.sorted(by: { $0.id < $1.id }) {
            let node = element(
                "capture", ("id", capture.id.rawValue), ("deviceUID", capture.deviceUID),
                ("deviceName", capture.deviceName), ("hostTimeNanos", String(capture.hostTimeNanos)),
                ("sampleTime", text(capture.sampleTime)), ("nominalSampleRate", text(capture.nominalSampleRate)),
                ("measuredSampleRate", text(capture.measuredSampleRate)), ("latency", String(capture.latency)))
            if let rate = capture.resampledFromRate { add(("resampledFromRate", text(rate)), to: node) }
            if !capture.driftCorrected { add(("driftCorrected", "false"), to: node) }
            captureList.addChild(node)
        }
        root.addChild(captureList)

        let fileList = element("files")
        for file in files.values.sorted(by: { $0.id < $1.id }) {
            let node = element(
                "file", ("id", file.id.rawValue), ("path", file.path), ("channels", String(file.layout.channelCount)),
                ("length", file.length.description))
            if let capture = file.capture { add(("capture", capture.rawValue), to: node) }
            fileList.addChild(node)
        }
        root.addChild(fileList)

        let trackList = element("tracks")
        for track in tracks {
            let node = element(
                "track", ("id", track.id.rawValue), ("name", track.name), ("gain", text(track.gain.dB)),
                ("layout", track.layout.rawValue))
            // A flag is written only when on, so a track with none keeps its old text (0039).
            if track.isMuted { add(("muted", "true"), to: node) }
            if track.isSoloed { add(("soloed", "true"), to: node) }
            switch track.route {
            case nil: break
            case .device(let uid, let channels):
                node.addChild(
                    element(
                        "route", ("device", uid), ("channels", channels.numbers.map(String.init).joined(separator: " "))
                    ))
            case .app(let bundleID): node.addChild(element("route", ("app", bundleID)))
            }
            for clip in track.clips {
                let clipNode = element(
                    "clip", ("id", clip.id.rawValue), ("file", clip.file.rawValue),
                    ("start", clip.start.description), ("offset", clip.offset.description),
                    ("length", clip.length.description), ("gain", text(clip.gain.dB)))
                // A fade of 0 is not written, so a clip with no fade keeps its version 1 text (0035).
                if clip.fades.fadeIn != .zero { add(("fadeIn", clip.fades.fadeIn.description), to: clipNode) }
                if clip.fades.fadeOut != .zero { add(("fadeOut", clip.fades.fadeOut.description), to: clipNode) }
                // A crossfade of 0 is not written either, so a clip with none keeps its old text (0036).
                if clip.crossfades.start != .zero {
                    add(("crossfadeIn", clip.crossfades.start.description), to: clipNode)
                }
                if clip.crossfades.end != .zero { add(("crossfadeOut", clip.crossfades.end.description), to: clipNode) }
                node.addChild(clipNode)
            }
            trackList.addChild(node)
        }
        root.addChild(trackList)

        let markerList = element("markers")
        for marker in sortedMarkers {
            let node = element(
                "marker", ("id", marker.id.rawValue), ("name", marker.name),
                ("position", marker.position.description), ("kind", marker.kind.rawValue))
            // Each field is written only with a value, so a marker with neither keeps its old text.
            if let url = marker.url { add(("url", url.text), to: node) }
            if let image = marker.image { add(("image", image.name), to: node) }
            markerList.addChild(node)
        }
        root.addChild(markerList)
        if !episode.isEmpty { root.addChild(episodeElement(episode)) }
        if !transcripts.isEmpty { root.addChild(transcriptsElement()) }

        if let recording {
            let node = element(
                "recording", ("take", String(recording.take)), ("playheadFrame", recording.playheadFrame.description),
                ("takeStartHostTimeNanos", String(recording.takeStartHostTimeNanos)))
            for track in recording.armedTracks { node.addChild(element("arm", ("track", track.rawValue))) }
            root.addChild(node)
        }

        let document = XMLDocument(rootElement: root)
        document.characterEncoding = "UTF-8"
        document.version = "1.0"
        return document
    }
}

extension Session {
    /// `<transcripts>` (decision 0055): one `<words>` element per file, one line per word,
    /// "number start end text", in the order of `Anchors`.
    fileprivate func transcriptsElement() -> XMLElement {
        let list = element("transcripts")
        for transcript in transcripts.values.sorted(by: { $0.id < $1.id }) {
            let node = element(
                "transcript", ("id", transcript.id.description), ("name", transcript.name),
                ("file", transcript.file.description))
            for (file, anchors) in (transcript.words ?? [:]).sorted(by: { $0.key < $1.key }) {
                let lines = anchors.all.map { "\($0.number) \($0.range.lowerBound) \($0.range.upperBound) \($0.text)" }
                let words = XMLElement(name: "words", stringValue: lines.joined(separator: "\n"))
                add(("file", file.rawValue), to: words)
                node.addChild(words)
            }
            list.addChild(node)
        }
        return list
    }
}

/// `<episode>` (decision 0045): each set field as an attribute, and `summary` and `notes` as
/// element text, which keeps line breaks and tabs.
private func episodeElement(_ episode: Episode) -> XMLElement {
    let node = element("episode")
    let attributes: [(String, String?)] = [
        ("title", episode.title?.text), ("show", episode.show?.text), ("author", episode.author?.text),
        ("number", episode.number?.description), ("season", episode.season?.description),
        ("date", episode.date?.description), ("language", episode.language?.code),
        ("copyright", episode.copyright?.text), ("explicit", episode.explicit ? "true" : nil),
        ("episodeURL", episode.episodeURL?.text), ("feedURL", episode.feedURL?.text), ("guid", episode.guid?.text),
        ("artwork", episode.artwork?.name),
    ]
    for case (let name, let value?) in attributes { add((name, value), to: node) }
    for (name, value) in [("summary", episode.summary?.text), ("notes", episode.notes?.text)] {
        if let value { node.addChild(XMLElement(name: name, stringValue: value)) }
    }
    return node
}

private func element(_ name: String, _ attributes: (String, String)...) -> XMLElement {
    let node = XMLElement(name: name)
    for attribute in attributes { add(attribute, to: node) }
    return node
}

private func add(_ attribute: (name: String, value: String), to element: XMLElement) {
    let node = XMLNode(kind: .attribute)
    node.name = attribute.name
    node.stringValue = attribute.value
    element.addAttribute(node)
}

/// Whole numbers without a decimal point ("0", "48000"); other values in the shortest text that
/// reads back to the same `Double` ("48000.37").
private func text(_ value: Double) -> String {
    if value == value.rounded(), abs(value) < 1e15 { return String(Int(value)) }
    return String(value)
}

/// Replaces `target` so that a crash or a power loss leaves the old file or the new file, never
/// a part: write a temporary file, flush it to the disk, rename it, then flush the folder.
func replaceDurably(_ target: URL, with data: Data) throws(SessionFileError) {
    let folder = target.deletingLastPathComponent()
    // One name per save, so two saves that overlap never write into the same file.
    let temporary = folder.appending(path: temporaryName(UUID()))

    do throws(SessionFileError) {
        try writeAndFlush(data, to: temporary.path)
        guard rename(temporary.path, target.path) == 0 else { throw posixError("rename") }
    } catch {
        unlink(temporary.path)
        throw error
    }
    try flush(folder.path)
}

private func temporaryName(_ uuid: UUID) -> String { ".session.xml.\(uuid.uuidString).tmp" }

private func isTemporaryName(_ name: String) -> Bool {
    guard let match = name.wholeMatch(of: /\.session\.xml\.(.+)\.tmp/), let uuid = UUID(uuidString: String(match.1))
    else { return false }
    return name == temporaryName(uuid)
}

private func writeAndFlush(_ data: Data, to path: String) throws(SessionFileError) {
    let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
    guard descriptor >= 0 else { throw posixError("open") }
    defer { close(descriptor) }
    // write() can return a short count; the next call then gives the real error, such as ENOSPC.
    let failure: Int32? = data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let written = write(descriptor, bytes.baseAddress.map { $0 + offset }, bytes.count - offset)
            if written >= 0 {
                offset += written
            } else if errno != EINTR {
                return errno
            }
        }
        return nil
    }
    if let failure { throw .writeFailed(step: "write", errno: failure) }
    try flush(descriptor)
}

private func flush(_ path: String) throws(SessionFileError) {
    let descriptor = open(path, O_RDONLY)
    guard descriptor >= 0 else { throw posixError("open") }
    defer { close(descriptor) }
    try flush(descriptor)
}

private func flush(_ descriptor: Int32) throws(SessionFileError) {
    if let code = fullFlush(descriptor) { throw .writeFailed(step: "fsync", errno: code) }
}

/// `F_FULLFSYNC` asks the drive to empty its cache. Some volumes (SMB, some external drives)
/// refuse it; then `fsync` is the best flush that they give. Returns the errno, or nil.
package func fullFlush(_ descriptor: Int32) -> Int32? {
    if fcntl(descriptor, F_FULLFSYNC) == 0 { return nil }
    return fsync(descriptor) == 0 ? nil : errno
}

/// Opens the file or folder at `path` for reading and flushes it. Returns the errno, or nil.
package func fullFlush(path: String) -> Int32? {
    let descriptor = open(path, O_RDONLY | O_CLOEXEC)
    guard descriptor >= 0 else { return errno }
    defer { close(descriptor) }
    return fullFlush(descriptor)
}

private func posixError(_ call: String) -> SessionFileError {
    .writeFailed(step: call, errno: errno)
}
