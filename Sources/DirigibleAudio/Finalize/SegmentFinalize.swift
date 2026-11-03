import AVFoundation
import DirigibleCore
import Foundation

/// Where one segment goes (decision 0021). A placement resolves it before the CAF opens, so the
/// finalize has no optional value and no index that can trap.
enum Target: Hashable, Sendable {
    /// At the recorded time of `recording` (the playhead, the host times, and the latency), on
    /// `track`.
    case aligned(Recording, track: TrackID)
    /// The whole segment at `start` on `track`.
    case fixed(track: TrackID, start: Frames)

    /// `track` and `start` when the call gives them; the rest from `anchor`, the track of the arm
    /// of `name` and the recorded time. Nil when a part is not known: no anchor, or an arm that
    /// the anchor does not have.
    init?(_ name: SegmentName, track: TrackID?, start: Frames?, anchor: Recording?) {
        let armed = anchor.flatMap { name.arm <= $0.armedTracks.count ? $0.armedTracks[name.arm - 1] : nil }
        guard let track = track ?? armed else { return nil }
        if let start {
            self = .fixed(track: track, start: start)
        } else if let anchor {
            self = .aligned(anchor, track: track)
        } else {
            return nil
        }
    }

    var track: TrackID {
        switch self {
        case .aligned(_, let track), .fixed(let track, _): track
        }
    }
}

/// The finalize of one segment.
struct SegmentFinalize {
    let name: SegmentName
    let target: Target
    let package: URL
    let readFault: ReadFault?
    let blockFrames: Int

    var caf: String { "\(captureFolderName)/\(name.stem).caf" }
    var sidecar: String { "\(captureFolderName)/\(name.stem).sidecar" }
    /// The WAV path in `Clips/`, and the path of the WAV until its read-back ends.
    var wavName: String { "\(name.stem).wav" }
    var temporaryWAVName: String { temporaryWAV(of: name.stem) }
    var wav: String { "\(clipsFolderName)/\(wavName)" }

    /// The session with the capture, the file, and the clip of the segment added, or the fault of
    /// the segment that keeps it unplaced. A segment with no frame after the floor (the playhead
    /// of an aligned target, 0 for a fixed one) gets no clip.
    func place(on session: Session) throws(FinalizeError) -> Result<Session, SegmentFault> {
        // Held open, so a read error with no errno can be checked on the same file.
        // A listed CAF that is gone is take-wide: the package moved during the finalize.
        let descriptor = open(package.appending(path: caf).path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            let code = errno
            throw code == ENOENT ? .readFailed(file: caf, errno: code) : unreadable(caf, code)
        }
        defer { close(descriptor) }
        let input: AVAudioFile
        do {
            input = try AVAudioFile(forReading: package.appending(path: caf))
        } catch {
            if let code = ioErrno(of: error, file: descriptor) { throw unreadable(caf, code) }
            return .failure(.badAudio)
        }
        guard input.length > 0 else { return .failure(.badAudio) }
        let sidecar: Sidecar
        switch try readSidecar() {
        case .success(let read): sidecar = read
        case .failure(let fault): return .failure(fault)
        }
        guard input.fileFormat.sampleRate == sidecar.header.nominalRate,
            Int(input.fileFormat.channelCount) == sidecar.header.channelCount
        else { return .failure(.badAudio) }
        // The errors of `Session.place`, before the conversion, so a bad target converts nothing.
        guard let track = session.track(target.track) else {
            return .failure(.session(.unknownTrack(target.track)))
        }
        guard ChannelLayout(channelCount: sidecar.header.channelCount) == track.layout else {
            return .failure(.session(.layoutMismatch(track.id, .file(FileID(name.stem)))))
        }
        // A user file with a stem path (`dirigible file add`) is never overwritten.
        if let user = poolFile(at: wavName, in: session) ?? poolFile(at: temporaryWAVName, in: session) {
            return .failure(.wavInUse(user))
        }
        let temporary = package.appending(path: "\(clipsFolderName)/\(temporaryWAVName)")
        // Each exit but the rename unlinks it, so a fault or a refusal (also a refusal of the
        // session after the conversion) leaves no WAV under either name.
        var renamed = false
        defer { if !renamed { unlink(temporary.path) } }
        let header = sidecar.header
        let choice = RateChoice(header: header, checkpoints: sidecar.checkpoints, frames: Int(input.length))
        let rate = Double(session.sampleRate)
        let conversion = ClipConversion(
            package: package, wav: wav, blockFrames: blockFrames,
            readFault: readFault?.stem == name.stem ? readFault : nil, unreadable: { unreadable(caf, $0) },
            channels: input.processingFormat.channelCount)
        guard
            let converted = try conversion.convert(
                input, file: descriptor, from: choice.source, to: rate, into: temporary)
        else { return .failure(.badAudio) }
        let (length, gain) = converted

        let id = name.stem
        let capture = Capture(
            id: CaptureID(id), deviceUID: header.deviceUID, deviceName: header.deviceName,
            hostTimeNanos: header.firstHostTimeNanos, sampleTime: header.firstSampleTime,
            nominalSampleRate: choice.nominal, measuredSampleRate: choice.measured, latency: header.latency,
            resampledFromRate: choice.source == rate ? nil : choice.source, driftCorrected: choice.driftCorrected)
        let (anchor, floor): (Int, Int)
        switch target {
        case .aligned(let recording, _):
            guard let aligned = capture.alignedStart(in: recording, sampleRate: session.sampleRate) else {
                return .failure(.badAudio)
            }
            (anchor, floor) = (aligned, recording.playheadFrame.count)
        case .fixed(_, let start):
            (anchor, floor) = (start.count, 0)
        }
        // A start before the floor moves into the file offset.
        let offset = max(0, floor - anchor)

        var copy = session
        do throws(SessionError) {
            try copy.addCapture(capture)
            try copy.addFile(
                AudioFile(
                    id: FileID(id), path: "\(id).wav", layout: ChannelLayout(channelCount: header.channelCount)!,
                    length: Frames(length), capture: CaptureID(id)))
            // A segment with no frame after the floor is a pool file with no clip.
            if length > offset {
                try copy.place(
                    Clip(
                        id: ClipID(id), file: FileID(id), start: Frames(anchor + offset), offset: Frames(offset),
                        length: Frames(length - offset), gain: gain),
                    on: target.track)
            }
        } catch {
            return .failure(.session(error))
        }
        guard rename(temporary.path, package.appending(path: wav).path) == 0 else {
            throw .writeFailed(file: wav, status: errno)
        }
        renamed = true
        return .success(copy)
    }

    /// The sidecar, or `.noSidecar` when it is missing or refused, or `.newerSidecar` when a newer
    /// build wrote it (decision 0024).
    func readSidecar() throws(FinalizeError) -> Result<Sidecar, SegmentFault> {
        let data: Data?
        do {
            data = try readPackageFile(sidecar, in: package)
        } catch .readFailed(let file, let code) {
            throw unreadable(file, code)
        }
        do throws(NewerFormat) {
            return try data.flatMap(Sidecar.decode).map { .success($0) } ?? .failure(.noSidecar)
        } catch {
            return .failure(.newerSidecar(version: error.version))
        }
    }

    /// A read errno of the CAF or the sidecar: the user can leave this segment (decision 0021).
    func unreadable(_ file: String, _ code: Int32) -> FinalizeError {
        .segmentUnreadable(name, file: file, errno: code)
    }
}

/// The pool file at `path` in `Clips/`. The compare drops "." and empty components and ignores
/// case, as the default APFS volume does. `ponytail:` a path compare only; add an inode compare if
/// a user links pool files.
private func poolFile(at path: String, in session: Session) -> FileID? {
    func key(_ path: String) -> String {
        path.split(separator: "/").filter { $0 != "." }.joined(separator: "/").lowercased()
    }
    return session.files.values.first { key($0.path) == key(path) }?.id
}
