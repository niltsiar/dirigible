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
}

/// The POSIX code under a Foundation file error, or EIO when there is none.
func posixCode(of error: any Error) -> Int32 {
    let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
    guard let underlying, underlying.domain == NSPOSIXErrorDomain else { return EIO }
    return Int32(underlying.code)
}

let sessionNamespace = "https://github.com/niltsiar/dirigible/session"
let sessionVersion = 1

extension Session {
    /// Writes `session.xml` in the package, and makes the package and its `Clips/` folder if
    /// they do not exist. The old file stays until the new file is complete and on the disk.
    public func write(to package: URL) throws(SessionFileError) {
        do {
            try FileManager.default.createDirectory(
                at: package.appending(path: "Clips"), withIntermediateDirectories: true)
        } catch {
            throw .writeFailed(step: "createDirectory", errno: posixCode(of: error))
        }
        try replaceDurably(
            package.appending(path: "session.xml"), with: xmlDocument().xmlData(options: .nodePrettyPrint))
    }

    func xmlDocument() -> XMLDocument {
        let root = element("session", ("version", String(sessionVersion)), ("sampleRate", String(sampleRate)))
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
            if let route = track.route {
                node.addChild(
                    element(
                        "route", ("device", route.deviceUID),
                        ("channels", route.channels.numbers.map(String.init).joined(separator: " "))))
            }
            for clip in track.clips {
                node.addChild(
                    element(
                        "clip", ("id", clip.id.rawValue), ("file", clip.file.rawValue),
                        ("start", clip.start.description), ("offset", clip.offset.description),
                        ("length", clip.length.description), ("gain", text(clip.gain.dB))))
            }
            trackList.addChild(node)
        }
        root.addChild(trackList)

        let markerList = element("markers")
        for marker in markers.values.sorted(by: { ($0.position, $0.id) < ($1.position, $1.id) }) {
            markerList.addChild(
                element(
                    "marker", ("id", marker.id.rawValue), ("name", marker.name),
                    ("position", marker.position.description), ("kind", marker.kind.rawValue)))
        }
        root.addChild(markerList)

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
private func replaceDurably(_ target: URL, with data: Data) throws(SessionFileError) {
    let folder = target.deletingLastPathComponent()
    let temporary = folder.appending(path: ".session.xml.tmp")

    do throws(SessionFileError) {
        try writeAndFlush(data, to: temporary.path)
        guard rename(temporary.path, target.path) == 0 else { throw posixError("rename") }
    } catch {
        unlink(temporary.path)
        throw error
    }
    try flush(folder.path)
}

private func writeAndFlush(_ data: Data, to path: String) throws(SessionFileError) {
    let descriptor = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    guard descriptor >= 0 else { throw posixError("open") }
    defer { close(descriptor) }
    let written = data.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
    guard written == data.count else { throw posixError("write") }
    try flush(descriptor)
}

private func flush(_ path: String) throws(SessionFileError) {
    let descriptor = open(path, O_RDONLY)
    guard descriptor >= 0 else { throw posixError("open") }
    defer { close(descriptor) }
    try flush(descriptor)
}

/// `F_FULLFSYNC` asks the drive to empty its cache. Some volumes (SMB, some external drives)
/// refuse it; then `fsync` is the best flush that they give.
private func flush(_ descriptor: Int32) throws(SessionFileError) {
    if fcntl(descriptor, F_FULLFSYNC) == 0 { return }
    guard fsync(descriptor) == 0 else { throw posixError("fsync") }
}

private func posixError(_ call: String) -> SessionFileError {
    .writeFailed(step: call, errno: errno)
}
