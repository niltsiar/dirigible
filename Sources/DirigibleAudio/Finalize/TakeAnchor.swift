import DirigibleCore
import Foundation

/// `Capture/take<n>.anchor` (decision 0021): the `Recording` of a take that ended. The finalize
/// that ends the take writes it before the save that removes `<recording>`, so a later placement
/// knows the track and the start of each segment of the take. The bytes use the sidecar framing:
/// an 8-byte magic, then one record. The reader refuses a torn or changed file.
enum TakeAnchor {
    private static let magic = Array("DRGANCH1".utf8)
    private static let kind: UInt8 = 1

    /// The package-relative path of the anchor of `take`.
    static func file(take: Int) -> String { "\(captureFolderName)/take\(take).anchor" }

    /// The payload: the take (UInt32), the playhead (Int64), the take start host time (UInt64),
    /// the track count (UInt32), then each track ID as a UInt32 byte count and its UTF-8 bytes.
    /// A UInt32 count, so no track ID length can trap the writer.
    static func encode(_ recording: Recording) -> Data {
        var payload = ByteWriter()
        payload.put(UInt32(truncatingIfNeeded: recording.take))
        payload.put(Int64(recording.playheadFrame.count))
        payload.put(recording.takeStartHostTimeNanos)
        payload.put(UInt32(truncatingIfNeeded: recording.armedTracks.count))
        for track in recording.armedTracks {
            let utf8 = Array(track.rawValue.utf8)
            payload.put(UInt32(truncatingIfNeeded: utf8.count))
            payload.bytes += utf8
        }
        return Data(magic) + Sidecar.record(kind, payload.bytes)
    }

    /// Nil for a bad magic, a short record, a bad hash, trailing bytes, or a value that
    /// `Session.setRecording` refuses; throws for an anchor of a newer version (decision 0024).
    /// `take` is the number in the file name, and the record must hold the same number.
    static func decode(_ data: Data, take: Int) throws(NewerFormat) -> Recording? {
        var reader = ByteReader(Array(data))
        guard try reader.magic(magic), let record = reader.record(), record.kind == kind,
            reader.isAtEnd
        else { return nil }
        var fields = ByteReader(Array(record.payload))
        guard let number: UInt32 = fields.integer(), let playhead: UInt64 = fields.integer(),
            let hostTime: UInt64 = fields.integer(), let count: UInt32 = fields.integer()
        else { return nil }
        var tracks: [TrackID] = []
        for _ in 0..<count {
            guard let length: UInt32 = fields.integer(), let utf8 = fields.take(Int(length)),
                let id = String(bytes: utf8, encoding: .utf8), id.unicodeScalars.allSatisfy(\.isStorableInSession)
            else { return nil }
            tracks.append(TrackID(id))
        }
        let frames = Frames(Int(Int64(bitPattern: playhead)))
        guard fields.isAtEnd, Int(number) == take, Recording.takes.contains(take), frames >= .zero, frames <= .limit
        else { return nil }
        return Recording(take: take, playheadFrame: frames, takeStartHostTimeNanos: hostTime, armedTracks: tracks)
    }

    /// Writes the anchor to a temporary file, flushes it, renames it, and flushes `Capture/`, so
    /// a crash leaves no anchor or the whole anchor. The caller holds the package lock, so a
    /// temporary file that is there is a leftover of a crash: it goes first, and the open
    /// truncates, so a leftover never blocks a take.
    static func write(_ recording: Recording, in package: URL) throws(FinalizeError) {
        let file = file(take: recording.take)
        let target = package.appending(path: file).path
        let temporary = package.appending(path: "\(captureFolderName)/.take\(recording.take).anchor.tmp").path
        unlink(temporary)
        do throws(FinalizeError) {
            let descriptor = open(temporary, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
            guard descriptor >= 0 else { throw .writeFailed(file: file, status: errno) }
            defer { close(descriptor) }
            do {
                try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).write(contentsOf: encode(recording))
            } catch {
                throw .writeFailed(file: file, status: posixCode(of: error) ?? EIO)
            }
            if let code = fullFlush(descriptor) { throw .writeFailed(file: file, status: code) }
            guard rename(temporary, target) == 0 else { throw .writeFailed(file: file, status: errno) }
        } catch {
            unlink(temporary)
            throw error
        }
        if let code = fullFlush(path: package.appending(path: captureFolderName).path) {
            throw .writeFailed(file: captureFolderName, status: code)
        }
    }

    /// The anchor of `take`, or `.failure` for an anchor of a newer version (decision 0024). Nil
    /// when the file is missing (ENOENT) or refused; another errno throws, so an I/O fault never
    /// reads as "no anchor".
    static func read(take: Int, in package: URL) throws(FinalizeError) -> Result<Recording, NewerFormat>? {
        guard let data = try readPackageFile(file(take: take), in: package) else { return nil }
        do throws(NewerFormat) {
            return try decode(data, take: take).map { .success($0) }
        } catch {
            return .failure(error)
        }
    }
}

/// The take anchors of a package, for the take map (decision 0061).
public enum TakeAnchors {
    /// The `Recording` of each `Capture/take<n>.anchor`, by take. A missing `Capture/`, a missing
    /// anchor, a newer anchor, and an anchor that the reader refuses give no entry. Another errno
    /// on `Capture/` or on an anchor throws `.readFailed`, so an I/O fault never reads as no take
    /// time.
    public static func read(_ package: URL) throws(FinalizeError) -> [Int: Recording] {
        let folder = package.appending(path: captureFolderName)
        if let code = openErrno(folder.path) {
            if code == ENOENT { return [:] }
            throw .readFailed(file: captureFolderName, errno: code)
        }
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        } catch {
            throw .readFailed(file: captureFolderName, errno: posixCode(of: error) ?? EIO)
        }
        var anchors: [Int: Recording] = [:]
        for name in names {
            guard let match = name.wholeMatch(of: /take([1-9][0-9]{0,8})\.anchor/), let take = Int(match.1) else {
                continue
            }
            if case .success(let recording) = try TakeAnchor.read(take: take, in: package) { anchors[take] = recording }
        }
        return anchors
    }
}

/// The anchor in `anchors` of the take of each capture of `session`, by the take number of the
/// capture ID (decision 0012). A capture whose take has no anchor gets no entry.
func takeRecordings(_ session: Session, anchors: [Int: Recording]) -> [CaptureID: Recording] {
    var recordings: [CaptureID: Recording] = [:]
    for id in session.captures.keys {
        if let take = SegmentName(id: id.rawValue)?.take, let recording = anchors[take] { recordings[id] = recording }
    }
    return recordings
}

extension TakeAnchors {
    /// `read(_:)` as a value, so a result can cross from a read off the main actor to the studio.
    public static func result(_ package: URL) -> Result<[Int: Recording], FinalizeError> {
        Result { () throws(FinalizeError) in try read(package) }
    }
}

extension TakeMap {
    /// The map of `session` with the anchors of its package (decision 0061). A read fault is the
    /// result only when the session has a take file, a file whose capture ID equals its file ID:
    /// with none, the session has no take audio, whatever `Capture/` holds.
    public static func of(_ session: Session, anchors: Result<[Int: Recording], FinalizeError>)
        -> Result<TakeMap, FinalizeError>
    {
        switch anchors {
        case .success(let anchors):
            return .success(TakeMap(session, recordings: takeRecordings(session, anchors: anchors)))
        case .failure(let error):
            let takeFile = session.files.values.contains(where: \.isTakeFile)
            return takeFile ? .failure(error) : .success(TakeMap(session, recordings: [:]))
        }
    }
}

extension FinalizeError {
    /// The package-relative file and the errno of the fault.
    public var fault: (file: String, errno: Int32) {
        switch self {
        case .readFailed(let file, let code), .segmentUnreadable(_, let file, let code),
            .writeFailed(let file, let code):
            (file, code)
        }
    }
}
