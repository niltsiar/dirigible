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

    var caf: String { "\(captureFolderName)/\(name.cafName)" }
    var sidecar: String { "\(captureFolderName)/\(name.sidecarName)" }
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
            // A CAF that decision 0071 removed: the WAV and the finalize record of the sidecar stay.
            if code == ENOENT, case .success(let sidecar) = try readSidecar(), let record = sidecar.finalized {
                return try placeFromWAV(sidecar.header, record, checkpoints: sidecar.checkpoints, on: session)
            }
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
        if let refusal = refusal(of: sidecar.header, on: session) { return .failure(refusal) }
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
        let placed = place(header, choice, source: choice.source, length: length, gain: gain, on: session)
        guard case .success = placed else { return placed }
        guard rename(temporary.path, package.appending(path: wav).path) == 0 else {
            throw .writeFailed(file: wav, status: errno)
        }
        renamed = true
        // With no flush: the sweep of decision 0071 flushes it before a CAF goes. A fault keeps no
        // record, and the sweep then reads the gain from the files.
        _ = Sidecar.append(
            FinalizeRecord(cafFrames: input.length, sourceRate: choice.source, conversionGain: gain),
            toSidecarAt: package.appending(path: self.sidecar))
        return placed
    }

    /// The placement of a segment whose CAF is gone (decision 0071): the WAV in `Clips/` as it is,
    /// with the capture of the sidecar and the record, and the gain of the record. It converts
    /// nothing.
    private func placeFromWAV(
        _ header: CaptureHeader, _ record: FinalizeRecord, checkpoints: [Checkpoint], on session: Session
    ) throws(FinalizeError) -> Result<Session, SegmentFault> {
        let url = package.appending(path: wav)
        if let code = openErrno(url.path) {
            throw code == ENOENT ? .readFailed(file: caf, errno: code) : unreadable(wav, code)
        }
        let length: AVAudioFramePosition
        do {
            let file = try AVAudioFile(forReading: url)
            guard file.fileFormat.sampleRate == Double(session.sampleRate),
                Int(file.fileFormat.channelCount) == header.channelCount
            else { return .failure(.badAudio) }
            length = file.length
        } catch {
            return .failure(.badAudio)
        }
        guard length > 0 else { return .failure(.badAudio) }
        if let refusal = refusal(of: header, on: session) { return .failure(refusal) }
        let choice = RateChoice(header: header, checkpoints: checkpoints, frames: Int(record.cafFrames))
        return place(
            header, choice, source: record.sourceRate, length: Int(length), gain: record.conversionGain, on: session)
    }

    /// The errors of `Session.place` before a conversion, so a bad target converts nothing.
    private func refusal(of header: CaptureHeader, on session: Session) -> SegmentFault? {
        guard let track = session.track(target.track) else { return .session(.unknownTrack(target.track)) }
        guard ChannelLayout(channelCount: header.channelCount) == track.layout else {
            return .session(.layoutMismatch(track.id, .file(FileID(name.stem))))
        }
        // A user file with a stem path (`dirigible file add`) is never overwritten.
        return (poolFile(at: wavName, in: session) ?? poolFile(at: temporaryWAVName, in: session)).map {
            .wavInUse($0)
        }
    }

    /// `session` with the capture, the file, and the clip of a WAV of `length` frames converted
    /// from `source`.
    private func place(
        _ header: CaptureHeader, _ choice: RateChoice, source: Double, length: Int, gain: Gain, on session: Session
    ) -> Result<Session, SegmentFault> {
        let id = name.stem
        let capture = Capture(
            id: CaptureID(id), deviceUID: header.deviceUID, deviceName: header.deviceName,
            hostTimeNanos: header.firstHostTimeNanos, sampleTime: header.firstSampleTime,
            nominalSampleRate: choice.nominal, measuredSampleRate: choice.measured, latency: header.latency,
            resampledFromRate: source == Double(session.sampleRate) ? nil : source,
            driftCorrected: choice.driftCorrected)
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
