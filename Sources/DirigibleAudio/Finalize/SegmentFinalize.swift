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
    var temporaryWAVName: String { ".\(name.stem).wav.tmp" }
    var wav: String { "\(clipsFolderName)/\(wavName)" }

    /// The session with the capture, the file, and the clip of the segment added, or the fault of
    /// the segment that keeps it unplaced.
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
        guard let sidecar = try readSidecar() else { return .failure(.noSidecar) }
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
        guard let length = try convert(input, file: descriptor, from: choice.source, to: rate, into: temporary) else {
            return .failure(.badAudio)
        }

        let anchor: Int
        switch target {
        case .aligned(let recording, _):
            let latency = (Double(header.latency) * rate / choice.nominal).rounded()
            let hostOffset =
                (Double(nanos(from: recording.takeStartHostTimeNanos, to: header.firstHostTimeNanos)) * rate / 1e9)
                .rounded()
            guard let aligned = Int(exactly: Double(recording.playheadFrame.count) + hostOffset - latency) else {
                return .failure(.badAudio)
            }
            anchor = aligned
        case .fixed(_, let start):
            anchor = start.count
        }
        // A negative start moves into the file offset.
        let offset = max(0, -anchor)
        guard length > offset else { return .failure(.beforeTimeline) }

        let id = name.stem
        var copy = session
        do throws(SessionError) {
            try copy.addCapture(
                Capture(
                    id: CaptureID(id), deviceUID: header.deviceUID, deviceName: header.deviceName,
                    hostTimeNanos: header.firstHostTimeNanos, sampleTime: header.firstSampleTime,
                    nominalSampleRate: choice.nominal, measuredSampleRate: choice.measured, latency: header.latency,
                    resampledFromRate: choice.source == rate ? nil : choice.source,
                    driftCorrected: choice.driftCorrected))
            try copy.addFile(
                AudioFile(
                    id: FileID(id), path: "\(id).wav", layout: ChannelLayout(channelCount: header.channelCount)!,
                    length: Frames(length), capture: CaptureID(id)))
            try copy.place(
                Clip(
                    id: ClipID(id), file: FileID(id), start: Frames(max(0, anchor)), offset: Frames(offset),
                    length: Frames(length - offset)),
                on: target.track)
        } catch {
            return .failure(.session(error))
        }
        guard rename(temporary.path, package.appending(path: wav).path) == 0 else {
            throw .writeFailed(file: wav, status: errno)
        }
        renamed = true
        return .success(copy)
    }

    /// Nil when the sidecar is missing or refused.
    func readSidecar() throws(FinalizeError) -> Sidecar? {
        do {
            return try readPackageFile(sidecar, in: package).flatMap(Sidecar.decode)
        } catch .readFailed(let file, let code) {
            throw unreadable(file, code)
        }
    }

    /// A read errno of the CAF or the sidecar: the user can leave this segment (decision 0021).
    func unreadable(_ file: String, _ code: Int32) -> FinalizeError {
        .segmentUnreadable(name, file: file, errno: code)
    }

    /// Reads `input` (open at `descriptor` too) in blocks, converts it from `source` to `rate`
    /// through one converter when the rates differ, and writes, flushes, and reads back the WAV at
    /// `url`, the temporary name. Returns the frame count of the WAV, or nil for a bad CAF, a
    /// converter that stops before the end of the stream, or a WAV length that does not read back.
    func convert(
        _ input: AVAudioFile, file descriptor: Int32, from source: Double, to rate: Double, into url: URL
    ) throws(FinalizeError) -> Int? {
        let channels = input.processingFormat.channelCount
        let capacity = AVAudioFrameCount(blockFrames)
        guard let output = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels),
            let read = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: capacity),
            let written = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity)
        else { return nil }
        try createClipsFolder(in: package)
        let writer = try ClipWriter(url: url, file: wav, format: output)
        let reader = BlockReader(
            input: input, descriptor: descriptor, buffer: read, fault: readFault?.stem == name.stem ? readFault : nil)
        var length = 0
        // The same-rate path has no converter and ends at the end of the stream.
        var status = AVAudioConverterOutputStatus.endOfStream

        if source == rate {
            while reader.next() {
                try writer.write(read)
                length += Int(read.frameLength)
            }
        } else {
            guard let from = AVAudioFormat(standardFormatWithSampleRate: source, channels: channels),
                let converter = AVAudioConverter(from: from, to: output),
                let fed = AVAudioPCMBuffer(pcmFormat: from, frameCapacity: capacity)
            else { return nil }
            converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
            converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Normal
            reader.relabeled = fed
            status = .haveData
            while status == .haveData {
                var error: NSError?
                status = converter.convert(to: written, error: &error) { _, inputStatus in
                    let block = reader.nextRelabeled()
                    inputStatus.pointee = block == nil ? .endOfStream : .haveData
                    return block
                }
                if reader.failure != nil || status == .error { break }
                try writer.write(written)
                length += Int(written.frameLength)
            }
        }
        if let failure = reader.failure { throw unreadable(caf, failure) }
        // A converter that ends in .error or .inputRanDry gives a short clip; a placed clip holds
        // the whole segment.
        guard !reader.unreadable, status == .endOfStream else { return nil }
        try writer.close()
        let clip = open(url.path, O_RDONLY | O_CLOEXEC)
        guard clip >= 0 else { throw .readFailed(file: wav, errno: errno) }
        defer { close(clip) }
        if let code = fullFlush(clip) { throw .writeFailed(file: wav, status: code) }
        do {
            guard try AVAudioFile(forReading: url).length == AVAudioFramePosition(length) else { return nil }
        } catch {
            if let code = ioErrno(of: error, file: clip) { throw .readFailed(file: wav, errno: code) }
            return nil
        }
        return length
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

/// Reads a file in blocks into one buffer. A read error that `ioErrno` gives an errno sets
/// `failure`; any other read error, or a read of no frames before the end, sets `unreadable`.
/// `@unchecked Sendable`: the converter input block is `@Sendable`, but the converter calls it
/// synchronously inside `convert`, so one thread at a time uses the reader.
private final class BlockReader: @unchecked Sendable {
    let input: AVAudioFile
    let descriptor: Int32
    let buffer: AVAudioPCMBuffer
    let fault: ReadFault?
    /// A buffer at the source rate that gets a copy of each block, for the converter.
    var relabeled: AVAudioPCMBuffer?
    private var block = 0
    private(set) var failure: Int32?
    private(set) var unreadable = false

    init(input: AVAudioFile, descriptor: Int32, buffer: AVAudioPCMBuffer, fault: ReadFault?) {
        self.input = input
        self.descriptor = descriptor
        self.buffer = buffer
        self.fault = fault
    }

    /// False at the end of the file or after an error.
    func next() -> Bool {
        guard failure == nil, !unreadable, input.framePosition < input.length else { return false }
        defer { block += 1 }
        do {
            if let fault, fault.block == block { try fault.before() }
            try input.read(into: buffer, frameCount: buffer.frameCapacity)
        } catch {
            if let code = ioErrno(of: error, file: descriptor) { failure = code } else { unreadable = true }
            return false
        }
        // A read of no frames before the end would give a short clip.
        if buffer.frameLength == 0 { unreadable = true }
        return !unreadable
    }

    /// The next block, copied into `relabeled`. Nil at the end of the file or after an error.
    func nextRelabeled() -> AVAudioPCMBuffer? {
        guard let relabeled, next(), let source = buffer.floatChannelData, let target = relabeled.floatChannelData
        else { return nil }
        relabeled.frameLength = buffer.frameLength
        for channel in 0..<Int(buffer.format.channelCount) {
            target[channel].update(from: source[channel], count: Int(buffer.frameLength))
        }
        return relabeled
    }
}
