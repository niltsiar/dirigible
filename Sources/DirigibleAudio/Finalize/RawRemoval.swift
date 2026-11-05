import AVFoundation
import Accelerate
import DirigibleCore
import Foundation

/// The gate verdict of one segment that has its CAF (decision 0071). The text of `info` and
/// `session_info` comes from it.
public enum RawVerdict: Hashable, Sendable {
    /// The segment is in the pending take.
    case pendingTake
    /// No clip of the session uses a pool file `<stem>.wav` that refers to the capture.
    case notPlaced
    /// Every clause holds. A CAF that stays waits for the next sweep.
    case removable
    /// G1: the WAV frames on disk do not match the pool file length or the CAF frames, or the CAF
    /// or the WAV does not open.
    case frames
    /// G2: `driftCorrected` is false, the sidecar does not read or has no usable fit, or the rate
    /// choice of the sidecar is not the `resampledFromRate` of the capture.
    case rateChoice
    /// G3: the largest WAV error against the host clock over the checkpoints, in seconds, is over
    /// 1 ms.
    case alignment(Double)
    /// Every clause holds, but the WAV of a build before the clip gain saturated where the CAF
    /// is over full scale, so only the CAF holds those samples (a saturated record in the sidecar).
    case saturated
}

/// Why a removal step kept a CAF that the gate passes. Only the journal gets it.
enum RawRemovalError: Error, Hashable, Sendable {
    case unreadable(file: String, errno: Int32)
    /// The CAF, the WAV, or the sidecar is not the file that the job read.
    case changed
    /// The sidecar does not decode with the finalize record that the job read.
    case recordMismatch
    case writeFailed(file: String, status: Int32)
    /// The unlink of the CAF failed.
    case removeFailed(errno: Int32)
}

/// The gate of decision 0071 for one placed segment. `cafFrames` and `wavFrames` are the frame
/// counts on disk; `file` and `capture` are the pool file and the capture of the session.
func rawVerdict(
    sidecar: Sidecar, cafFrames: Int, wavFrames: Int, file: AudioFile, capture: Capture, sessionRate: Int
) -> RawVerdict {
    let header = sidecar.header
    let choice = RateChoice(header: header, checkpoints: sidecar.checkpoints, frames: cafFrames)
    let rate = Double(sessionRate)
    let resampled = choice.source == rate ? nil : choice.source
    // A trusted fit has 2 or more checkpoints, so G3 below never passes on no checkpoints.
    guard capture.driftCorrected, choice.driftCorrected, capture.resampledFromRate == resampled else {
        return .rateChoice
    }
    let expected = Double(cafFrames) * rate / choice.source
    let lengthMatches = resampled == nil ? wavFrames == cafFrames : abs(Double(wavFrames) - expected) < 1
    guard wavFrames == file.length.count, lengthMatches else { return .frames }
    let error = sidecar.checkpoints.reduce(0.0) { worst, checkpoint in
        let host = Double(nanos(from: header.firstHostTimeNanos, to: checkpoint.hostTimeNanos)) / 1e9
        return max(worst, abs(Double(checkpoint.fileFrame) / choice.source - host))
    }
    return error <= 1e-3 ? .removable : .alignment(error)
}

/// The verdict of each segment whose CAF is in `Capture/`. A segment is placed when it is not in
/// the pending take, its pool file has the path `<stem>.wav` and refers to its capture, and a clip
/// of `session` uses that pool file; only a placed segment gets the gate. It reads file headers
/// and sidecars and writes nothing, so call it off the main actor.
public func rawCaptures(of session: Session, in package: URL) -> [SegmentName: RawVerdict] {
    var verdicts: [SegmentName: RawVerdict] = [:]
    for name in (try? captureSegments(in: package)) ?? [] {
        verdicts[name] = verdict(of: name, session: session, in: package)
    }
    return verdicts
}

/// The verdict of one segment of `rawCaptures`.
private func verdict(of name: SegmentName, session: Session, in package: URL) -> RawVerdict {
    guard name.take != session.recording?.take else { return .pendingTake }
    guard let file = session.files[FileID(name.stem)], file.path == "\(name.stem).wav",
        file.capture == CaptureID(name.stem),
        session.tracks.contains(where: { $0.clips.contains { $0.file == file.id } })
    else { return .notPlaced }
    return rawVerdict(of: name, file: file, session: session, in: package)
}

/// The device, the inode, and the size of one file.
struct FileIdentity: Hashable, Sendable {
    var device: Int32
    var inode: UInt64
    var size: Int64

    init?(path: String) {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        (device, inode, size) = (info.st_dev, info.st_ino, info.st_size)
    }
}

/// What the sweep job read of one segment that passes the gate: the identity of its CAF, its WAV,
/// and its sidecar, and its finalize record. Its removal checks them again.
struct RawRead: Hashable, Sendable {
    var files: [FileIdentity?]
    var record: FinalizeRecord
    /// True for a take with no finalize record: the removal appends `record` first.
    var appends = false
    /// True for a take with no finalize record whose WAV saturated (`rawGain`): the removal
    /// appends a saturated record of the CAF frames of `record` and keeps the CAF.
    var saturated = false
}

/// The placed segments that pass the gate (decision 0071), in name order, with the identity of
/// their files and their finalize record: nil for a take that a build before 0071 finalized. It
/// returns no segment on a volume that is read-only or does not say, so no removal path unlinks
/// there. It reads `isCancelled` after `beforeSegment` with the index of each segment, and after
/// a cancel it returns no segment. It reads file headers and sidecars and no audio, so call it
/// off the main actor.
func removableCaptures(
    of session: Session, in package: URL, isCancelled: () -> Bool = { false },
    beforeSegment: (Int) -> Void = { _ in }
) -> [(name: SegmentName, files: [FileIdentity?], record: FinalizeRecord?)] {
    guard (try? package.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == false else {
        return []
    }
    var removable: [(name: SegmentName, files: [FileIdentity?], record: FinalizeRecord?)] = []
    for (index, name) in ((try? captureSegments(in: package)) ?? []).enumerated() {
        beforeSegment(index)
        if isCancelled() { return [] }
        guard verdict(of: name, session: session, in: package) == .removable else { continue }
        removable.append((name, rawFiles(of: name, in: package), finalizeRecord(of: name, in: package)))
    }
    return removable
}

/// The finalize record of a segment with no record: the CAF frames, the rate choice of its
/// sidecar, and `rawGain`, with `saturated` of `rawGain`. Nil after a cancel, or when a file does
/// not read whole.
func oldTakeRecord(
    of segment: SegmentName, in package: URL, isCancelled: @escaping () -> Bool,
    beforeBlock: (Int) -> Void
) throws(RawRemovalError) -> (record: FinalizeRecord, saturated: Bool)? {
    guard let data = try? readPackageFile("\(captureFolderName)/\(segment.sidecarName)", in: package),
        let sidecar = try? Sidecar.decode(data),
        let caf = try? AVAudioFile(forReading: package.appending(path: "\(captureFolderName)/\(segment.cafName)")),
        let gain = try rawGain(of: segment, in: package, isCancelled: isCancelled, beforeBlock: beforeBlock)
    else { return nil }
    let choice = RateChoice(header: sidecar.header, checkpoints: sidecar.checkpoints, frames: Int(caf.length))
    return (FinalizeRecord(cafFrames: caf.length, sourceRate: choice.source, conversionGain: gain.gain), gain.saturated)
}

/// One removal of decision 0071 in a turn of the write chain, where `session` is the session on
/// the disk: the gate again, the identity of the three files against `read`, then for `appends`
/// the flush of the WAV and of `Clips/` and the append of the record, then the sidecar flush, its
/// record against `read` and against the CAF header frames and the rate choice, the unlink of the
/// CAF, and the flush of `Capture/`. False when the gate
/// does not pass now; then no file changes. For `saturated`, it appends and flushes only the
/// saturated record, and returns false. `flush` gives the errno of a flush. Call it off the main
/// actor.
func removeRawCapture(
    _ name: SegmentName, of session: Session, in package: URL, read: RawRead,
    flush: (String) -> Int32? = { fullFlush(path: $0) }
) throws(RawRemovalError) -> Bool {
    guard verdict(of: name, session: session, in: package) == .removable else { return false }
    guard rawFiles(of: name, in: package) == read.files else { throw .changed }
    let sidecar = "\(captureFolderName)/\(name.sidecarName)"
    if read.saturated {
        let url = package.appending(path: sidecar)
        if let code = Sidecar.append(Sidecar.encode(saturated: read.record.cafFrames), toSidecarAt: url)
            ?? flush(url.path)
        {
            throw .writeFailed(file: sidecar, status: code)
        }
        return false
    }
    if read.appends {
        // A build before 0071 can have left the WAV and its name in Clips/ in the cache only.
        for file in ["\(clipsFolderName)/\(name.stem).wav", clipsFolderName] {
            if let code = flush(package.appending(path: file).path) {
                throw .writeFailed(file: file, status: code)
            }
        }
        if let code = Sidecar.append(read.record, toSidecarAt: package.appending(path: sidecar)) {
            throw .writeFailed(file: sidecar, status: code)
        }
    }
    if let code = flush(package.appending(path: sidecar).path) {
        throw .writeFailed(file: sidecar, status: code)
    }
    guard recordMatches(read.record, of: name, in: package) else { throw .recordMismatch }
    guard unlink(package.appending(path: "\(captureFolderName)/\(name.cafName)").path) == 0 else {
        throw .removeFailed(errno: errno)
    }
    if let code = flush(package.appending(path: captureFolderName).path) {
        throw .writeFailed(file: captureFolderName, status: code)
    }
    return true
}

/// The removal of a locked CLI or MCP edit (decision 0071), where `session` is the session on the
/// disk under the package lock: `removeRawCapture` for each placed segment that passes the gate and
/// has a valid finalize record. It reads no audio, so a take with no record keeps its CAF. Writes
/// one `raw` line for each fault to `log()`, which it calls only at the first fault.
package func removeRecordedRawCaptures(of session: Session, in package: URL, log: () -> DiagnosticLog) {
    var journal: DiagnosticLog?
    for candidate in removableCaptures(of: session, in: package) {
        guard let record = candidate.record else { continue }
        do throws(RawRemovalError) {
            let read = RawRead(files: candidate.files, record: record)
            _ = try removeRawCapture(candidate.name, of: session, in: package, read: read)
        } catch {
            let started = journal ?? log()
            journal = started
            started.noteRawFault(candidate.name, error)
        }
    }
}

extension DiagnosticLog {
    /// One `raw` line of the journal (decision 0059).
    func noteRawFault(_ name: SegmentName, _ error: RawRemovalError) {
        let (fault, code) = error.journal
        note(
            .raw, "fault", level: .error,
            ["segment": .text(name.stem), "error": .text(fault), "errno": .number(Int64(code))])
    }
}

/// The CAF, the WAV, and the sidecar of `name`, in that order.
private func rawFiles(of name: SegmentName, in package: URL) -> [FileIdentity?] {
    [
        "\(captureFolderName)/\(name.cafName)", "\(clipsFolderName)/\(name.stem).wav",
        "\(captureFolderName)/\(name.sidecarName)",
    ]
    .map { FileIdentity(path: package.appending(path: $0).path) }
}

/// True when the sidecar of `name` decodes with `record` as its finalize record, and `record` has
/// the frames of the CAF header and the source rate of `RateChoice`.
private func recordMatches(_ record: FinalizeRecord, of name: SegmentName, in package: URL) -> Bool {
    guard let data = try? readPackageFile("\(captureFolderName)/\(name.sidecarName)", in: package),
        let sidecar = try? Sidecar.decode(data), sidecar.finalized == record,
        let caf = try? AVAudioFile(forReading: package.appending(path: "\(captureFolderName)/\(name.cafName)"))
    else { return false }
    let choice = RateChoice(header: sidecar.header, checkpoints: sidecar.checkpoints, frames: Int(caf.length))
    return record.cafFrames == caf.length && record.sourceRate == choice.source
}

private func finalizeRecord(of name: SegmentName, in package: URL) -> FinalizeRecord? {
    (try? readPackageFile("\(captureFolderName)/\(name.sidecarName)", in: package)).flatMap {
        try? Sidecar.decode($0)
    }?.finalized
}

private func rawVerdict(of name: SegmentName, file: AudioFile, session: Session, in package: URL) -> RawVerdict {
    guard let capture = session.captures[CaptureID(name.stem)],
        let data = try? readPackageFile("\(captureFolderName)/\(name.sidecarName)", in: package),
        let sidecar = try? Sidecar.decode(data)
    else { return .rateChoice }
    guard let caf = try? AVAudioFile(forReading: package.appending(path: "\(captureFolderName)/\(name.cafName)")),
        let wav = try? AVAudioFile(forReading: package.appending(path: "\(clipsFolderName)/\(file.path)"))
    else { return .frames }
    let verdict = rawVerdict(
        sidecar: sidecar, cafFrames: Int(caf.length), wavFrames: Int(wav.length), file: file, capture: capture,
        sessionRate: session.sampleRate)
    let saturated = sidecar.finalized == nil && sidecar.saturatedFrames == caf.length
    return verdict == .removable && saturated ? .saturated : verdict
}

/// The conversion gain of a segment with no valid finalize record (decision 0071). A WAV peak
/// magnitude at code 8388604 or less gives 0 dB with no CAF read: a rescaled WAV has its peak at
/// code 8388605 or 8388606. Else one converter pass of the CAF with no writer gives the peak
/// after the converter. Over 1.0, the gain is the gain of `ClipConversion` for that peak, but
/// 0 dB and `saturated` for a WAV at code 8388607 or 8388608: a saturated WAV of a build before
/// the clip gain. Each code is a magnitude, so 8388608 is a sample at -1.0. Nil after a cancel, or when the WAV,
/// the sidecar, or the CAF does not read whole. `isCancelled` is read before each block, after
/// `beforeBlock` with the index of each WAV block. `readFault` is a test seam on the CAF blocks.
func rawGain(
    of segment: SegmentName, in package: URL, isCancelled: @escaping () -> Bool,
    beforeBlock: (Int) -> Void = { _ in }, readFault: ReadFault? = nil
) throws(RawRemovalError) -> (gain: Gain, saturated: Bool)? {
    let wav = "\(clipsFolderName)/\(segment.stem).wav"
    guard let wavPeak = try peakCode(of: wav, in: package, isCancelled: isCancelled, beforeBlock: beforeBlock)
    else { return nil }
    if wavPeak.code <= 8_388_604 { return (.zero, false) }
    let caf = "\(captureFolderName)/\(segment.cafName)"
    let sidecarData: Data?
    do {
        sidecarData = try readPackageFile("\(captureFolderName)/\(segment.sidecarName)", in: package)
    } catch {
        throw RawRemovalError(error)
    }
    guard let sidecar = try? sidecarData.flatMap(Sidecar.decode) else { return nil }
    let descriptor = open(package.appending(path: caf).path, O_RDONLY | O_CLOEXEC)
    guard descriptor >= 0 else { throw .unreadable(file: caf, errno: errno) }
    defer { close(descriptor) }
    let input: AVAudioFile
    do {
        input = try AVAudioFile(forReading: package.appending(path: caf))
    } catch {
        if let code = ioErrno(of: error, file: descriptor) { throw .unreadable(file: caf, errno: code) }
        return nil
    }
    let choice = RateChoice(header: sidecar.header, checkpoints: sidecar.checkpoints, frames: Int(input.length))
    var conversion = ClipConversion(
        package: package, wav: wav, blockFrames: 65_536, readFault: readFault,
        unreadable: { .readFailed(file: caf, errno: $0) }, channels: input.processingFormat.channelCount)
    conversion.isCancelled = isCancelled
    let peak: Float?
    do {
        peak = try conversion.peak(input, file: descriptor, from: choice.source, to: wavPeak.rate)
    } catch {
        throw RawRemovalError(error)
    }
    guard let peak else { return nil }
    guard let rescale = rescale(peak: peak) else { return (.zero, false) }
    return wavPeak.code <= 8_388_606 ? (rescale.gain, false) : (.zero, true)
}

/// The peak magnitude of the WAV at `file` as a 24-bit code (full scale 8388608), and its rate.
/// Nil after a cancel, or for a file that is not audio or does not read whole.
private func peakCode(
    of file: String, in package: URL, isCancelled: () -> Bool, beforeBlock: (Int) -> Void
) throws(RawRemovalError) -> (code: Int, rate: Double)? {
    let url = package.appending(path: file)
    let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
    guard descriptor >= 0 else { throw .unreadable(file: file, errno: errno) }
    defer { close(descriptor) }
    do {
        let input = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 65_536) else {
            return nil
        }
        var (peak, block): (Float, Int) = (0, 0)
        while input.framePosition < input.length {
            beforeBlock(block)
            block += 1
            if isCancelled() { return nil }
            try input.read(into: buffer)
            guard buffer.frameLength > 0, let data = buffer.floatChannelData else { return nil }
            for channel in 0..<Int(buffer.format.channelCount) {
                var level: Float = 0
                vDSP_maxmgv(data[channel], 1, &level, vDSP_Length(buffer.frameLength))
                peak = max(peak, level)
            }
        }
        return (Int((Double(peak) * 8_388_608).rounded()), input.fileFormat.sampleRate)
    } catch {
        if let code = ioErrno(of: error, file: descriptor) { throw .unreadable(file: file, errno: code) }
        return nil
    }
}

extension RawRemovalError {
    /// The case name and the errno or status of the `raw` journal line (decision 0059).
    var journal: (name: String, code: Int32) {
        switch self {
        case .unreadable(_, let code): ("unreadable", code)
        case .changed: ("changed", 0)
        case .recordMismatch: ("recordMismatch", 0)
        case .writeFailed(_, let status): ("writeFailed", status)
        case .removeFailed(let code): ("removeFailed", code)
        }
    }

    init(_ error: FinalizeError) {
        switch error {
        case .readFailed(let file, let code), .segmentUnreadable(_, let file, let code):
            self = .unreadable(file: file, errno: code)
        case .writeFailed(let file, let status):
            self = .writeFailed(file: file, status: status)
        }
    }
}
