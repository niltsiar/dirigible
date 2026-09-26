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
    /// `Session.setRecording` refuses. `take` is the number in the file name, and the record must
    /// hold the same number.
    static func decode(_ data: Data, take: Int) -> Recording? {
        var reader = ByteReader(Array(data))
        guard reader.take(magic.count).map(Array.init) == magic, let record = reader.record(), record.kind == kind,
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

    /// The anchor of `take`. Nil when the file is missing (ENOENT) or refused; another errno
    /// throws, so an I/O fault never reads as "no anchor".
    static func read(take: Int, in package: URL) throws(FinalizeError) -> Recording? {
        try readPackageFile(file(take: take), in: package).flatMap { decode($0, take: take) }
    }
}
