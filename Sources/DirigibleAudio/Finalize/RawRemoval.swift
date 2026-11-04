import AVFoundation
import Accelerate
import DirigibleCore
import Foundation

/// The gate verdict of one placed segment (decision 0071). The text of `info` and
/// `session_info` comes from it.
public enum RawVerdict: Hashable, Sendable {
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
}

/// Why a removal step kept a CAF that the gate passes. Only the journal gets it.
enum RawRemovalError: Error, Hashable, Sendable {
    case unreadable(file: String, errno: Int32)
    case writeFailed(file: String, status: Int32)
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

/// The verdict of each placed segment whose CAF is in `Capture/`. A segment is placed when it is
/// not in the pending take, its pool file has the path `<stem>.wav` and refers to its capture,
/// and a clip of `session` uses that pool file. It reads file headers and sidecars and writes
/// nothing, so call it off the main actor.
public func rawCaptures(of session: Session, in package: URL) -> [SegmentName: RawVerdict] {
    let used = Set(session.tracks.flatMap { $0.clips.map(\.file) })
    var verdicts: [SegmentName: RawVerdict] = [:]
    for name in (try? captureSegments(in: package)) ?? [] where name.take != session.recording?.take {
        guard let file = session.files[FileID(name.stem)], file.path == "\(name.stem).wav",
            file.capture == CaptureID(name.stem), used.contains(file.id)
        else { continue }
        verdicts[name] = rawVerdict(of: name, file: file, session: session, in: package)
    }
    return verdicts
}

private func rawVerdict(of name: SegmentName, file: AudioFile, session: Session, in package: URL) -> RawVerdict {
    guard let capture = session.captures[CaptureID(name.stem)],
        let data = try? readPackageFile("\(captureFolderName)/\(name.stem).sidecar", in: package),
        let sidecar = try? Sidecar.decode(data)
    else { return .rateChoice }
    guard let caf = try? AVAudioFile(forReading: package.appending(path: "\(captureFolderName)/\(name.stem).caf")),
        let wav = try? AVAudioFile(forReading: package.appending(path: "\(clipsFolderName)/\(file.path)"))
    else { return .frames }
    return rawVerdict(
        sidecar: sidecar, cafFrames: Int(caf.length), wavFrames: Int(wav.length), file: file, capture: capture,
        sessionRate: session.sampleRate)
}

/// The conversion gain of a segment with no valid finalize record (decision 0071). A WAV peak
/// magnitude at code 8388604 or less gives 0 dB with no CAF read: a rescaled WAV has its peak at
/// code 8388605 or 8388606. Else one converter pass of the CAF with no writer gives the peak
/// after the converter. Over 1.0, the gain is the gain of `ClipConversion` for that peak, but
/// 0 dB for a WAV at code 8388607 or 8388608: a saturated WAV of a build before the clip gain.
/// Each code is a magnitude, so 8388608 is a sample at -1.0. Nil after a cancel, or when the WAV,
/// the sidecar, or the CAF does not read whole. `isCancelled` is read before each block.
/// `readFault` is a test seam on the CAF blocks.
func rawGain(
    of segment: SegmentName, in package: URL, isCancelled: @escaping () -> Bool, readFault: ReadFault? = nil
) throws(RawRemovalError) -> Gain? {
    let wav = "\(clipsFolderName)/\(segment.stem).wav"
    guard let wavPeak = try peakCode(of: wav, in: package, isCancelled: isCancelled) else { return nil }
    if wavPeak.code <= 8_388_604 { return .zero }
    let caf = "\(captureFolderName)/\(segment.stem).caf"
    let sidecarData: Data?
    do {
        sidecarData = try readPackageFile("\(captureFolderName)/\(segment.stem).sidecar", in: package)
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
    guard let rescale = rescale(peak: peak), wavPeak.code <= 8_388_606 else { return .zero }
    return rescale.gain
}

/// The peak magnitude of the WAV at `file` as a 24-bit code (full scale 8388608), and its rate.
/// Nil after a cancel, or for a file that is not audio or does not read whole.
private func peakCode(of file: String, in package: URL, isCancelled: () -> Bool) throws(RawRemovalError) -> (
    code: Int, rate: Double
)? {
    let url = package.appending(path: file)
    let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
    guard descriptor >= 0 else { throw .unreadable(file: file, errno: errno) }
    defer { close(descriptor) }
    do {
        let input = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 65_536) else {
            return nil
        }
        var peak: Float = 0
        while input.framePosition < input.length {
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
    init(_ error: FinalizeError) {
        switch error {
        case .readFailed(let file, let code), .segmentUnreadable(_, let file, let code):
            self = .unreadable(file: file, errno: code)
        case .writeFailed(let file, let status):
            self = .writeFailed(file: file, status: status)
        }
    }
}
