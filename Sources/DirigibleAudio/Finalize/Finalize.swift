import AVFoundation
import DirigibleCore
import Foundation

/// Only faults that can go away (decision 0012). The take stays pending and a retry can succeed.
public enum FinalizeError: Error, Hashable, Sendable {
    /// `Capture/` or a segment file does not open or read, with an errno other than ENOENT (for
    /// example EACCES, EIO, EMFILE). A CAF read that fails in the middle with an errno is this
    /// case, not an unplaced segment.
    case readFailed(file: String, errno: Int32)
    /// `Clips/` or a WAV cannot be made, written, or closed (for example ENOSPC, EACCES).
    case writeFailed(file: String, status: Int32)
}

/// A test seam: fails the read of block `block` (0-based) of one segment with `errno`. Only tests
/// pass it; `Studio` and the CLI never do.
struct ReadFault: Sendable {
    var stem: String
    var block: Int
    var errno: Int32
}

/// Reads every segment of `session.recording` in `Capture/`, writes each WAV to `Clips/`, and
/// returns the session with the captures, files, and clips added and `recording` removed. It
/// never writes `session.xml`. A second run overwrites the WAVs of the first.
///
/// A fault of one segment skips that segment: its capture, file, and clip are not added, and it
/// stays unplaced. Only a fault that can go away throws, and then nothing is placed. Each segment
/// is read and converted in blocks, so the memory does not grow with the take length.
func finalizeTake(
    of session: Session, in package: URL, readFault: ReadFault? = nil, blockFrames: Int = 65_536
) throws(FinalizeError) -> Session {
    guard let recording = session.recording else { return session }
    var result = session
    for name in try captureSegments(in: package)
    where name.take == recording.take && name.arm <= recording.armedTracks.count {
        let segment = SegmentFinalize(
            name: name, track: recording.armedTracks[name.arm - 1], recording: recording, package: package,
            readFault: readFault, blockFrames: blockFrames)
        if let placed = try segment.place(on: result) { result = placed }
    }
    try? result.setRecording(nil)  // Removing the recording never throws.
    return result
}

/// The stems of the CAFs in `Capture/` that have frames (or do not open), whose take is not the
/// pending take, and that no file of the session refers to. In name order. Nothing stores this
/// list; the disk holds the fact (decision 0012).
func unplacedSegments(in package: URL, session: Session) -> [String] {
    let referenced = Set(session.files.values.compactMap(\.capture))
    return ((try? captureSegments(in: package)) ?? [])
        .filter { $0.take != session.recording?.take && !referenced.contains(CaptureID($0.stem)) }
        .filter { name in
            let file = try? AVAudioFile(forReading: package.appending(path: "Capture/\(name.stem).caf"))
            return (file?.length ?? 1) > 0
        }
        .map(\.stem)
}

/// The segment names of the CAFs in `Capture/`, in name order. A missing folder has none.
func captureSegments(in package: URL) throws(FinalizeError) -> [SegmentName] {
    let folder = package.appending(path: "Capture")
    if let code = openErrno(folder.path) {
        if code == ENOENT { return [] }
        throw .readFailed(file: "Capture", errno: code)
    }
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else {
        throw .readFailed(file: "Capture", errno: EIO)
    }
    return names.filter { $0.hasSuffix(".caf") }.compactMap(SegmentName.init(fileName:)).sorted()
}

/// The errno of `open(path, O_RDONLY)`, or nil when the file opens.
func openErrno(_ path: String) -> Int32? {
    let descriptor = open(path, O_RDONLY | O_CLOEXEC)
    guard descriptor >= 0 else { return errno }
    close(descriptor)
    return nil
}

/// The POSIX code under a Foundation or AVFoundation error, or nil when there is none.
func posixCode(of error: any Error) -> Int32? {
    var current: NSError? = error as NSError
    while let error = current {
        if error.domain == NSPOSIXErrorDomain { return Int32(error.code) }
        current = error.userInfo[NSUnderlyingErrorKey] as? NSError
    }
    return nil
}

/// The finalize of one segment.
private struct SegmentFinalize {
    let name: SegmentName
    let track: TrackID
    let recording: Recording
    let package: URL
    let readFault: ReadFault?
    let blockFrames: Int

    var caf: String { "Capture/\(name.stem).caf" }
    var sidecar: String { "Capture/\(name.stem).sidecar" }
    var wav: String { "Clips/\(name.stem).wav" }

    /// The session with the capture, the file, and the clip of the segment added. Nil when the
    /// segment has no frames, or has a fault of its own and stays unplaced.
    func place(on session: Session) throws(FinalizeError) -> Session? {
        if let code = openErrno(package.appending(path: caf).path) {
            if code == ENOENT { return nil }
            throw .readFailed(file: caf, errno: code)
        }
        guard let input = try? AVAudioFile(forReading: package.appending(path: caf)), input.length > 0,
            let sidecar = try readSidecar(), input.fileFormat.sampleRate == sidecar.header.nominalRate,
            Int(input.fileFormat.channelCount) == sidecar.header.channelCount
        else { return nil }
        let header = sidecar.header
        let choice = RateChoice(header: header, checkpoints: sidecar.checkpoints)
        let rate = Double(session.sampleRate)
        guard let length = try convert(input, from: choice.source, to: rate) else { return nil }

        let latency = (Double(header.latency) * rate / choice.nominal).rounded()
        let hostOffset =
            (Double(nanos(from: recording.takeStartHostTimeNanos, to: header.firstHostTimeNanos)) * rate / 1e9)
            .rounded()
        guard let anchor = Int(exactly: Double(recording.playheadFrame.count) + hostOffset - latency) else {
            return nil
        }
        // A negative start moves into the file offset.
        let offset = max(0, -anchor)
        guard length > offset else { return nil }

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
                on: track)
        } catch {
            return nil
        }
        return copy
    }

    /// Nil when the sidecar is missing or refused.
    func readSidecar() throws(FinalizeError) -> Sidecar? {
        let url = package.appending(path: sidecar)
        if let code = openErrno(url.path) {
            if code == ENOENT { return nil }
            throw .readFailed(file: sidecar, errno: code)
        }
        do {
            return Sidecar.decode(try Data(contentsOf: url))
        } catch {
            throw .readFailed(file: sidecar, errno: posixCode(of: error) ?? EIO)
        }
    }

    /// Reads `input` in blocks, converts it from `source` to `rate` through one converter when
    /// the rates differ, and writes the WAV. Returns the frame count of the WAV, or nil for a
    /// read or converter error with no errno, or a WAV length that does not read back.
    func convert(_ input: AVAudioFile, from source: Double, to rate: Double) throws(FinalizeError) -> Int? {
        let channels = input.processingFormat.channelCount
        let capacity = AVAudioFrameCount(blockFrames)
        guard let output = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels),
            let read = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: capacity),
            let written = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity)
        else { return nil }
        try createClipsFolder()
        let url = package.appending(path: wav)
        let writer = try ClipWriter(url: url, file: wav, format: output)
        let reader = BlockReader(input: input, buffer: read, fault: readFault?.stem == name.stem ? readFault : nil)
        var length = 0

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
            var status = AVAudioConverterOutputStatus.haveData
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
        if let failure = reader.failure { throw .readFailed(file: caf, errno: failure) }
        guard !reader.unreadable else { return nil }
        try writer.close()
        guard (try? AVAudioFile(forReading: url).length) == AVAudioFramePosition(length) else { return nil }
        return length
    }

    func createClipsFolder() throws(FinalizeError) {
        do {
            try FileManager.default.createDirectory(
                at: package.appending(path: "Clips"), withIntermediateDirectories: true)
        } catch {
            throw .writeFailed(file: "Clips", status: posixCode(of: error) ?? EIO)
        }
    }
}

/// Reads a file in blocks into one buffer. A read error with an errno sets `failure`; one
/// without an errno sets `unreadable`. `@unchecked Sendable`: the converter input block is
/// `@Sendable`, but the converter calls it synchronously inside `convert`, so one thread at a time
/// uses the reader.
private final class BlockReader: @unchecked Sendable {
    let input: AVAudioFile
    let buffer: AVAudioPCMBuffer
    let fault: ReadFault?
    /// A buffer at the source rate that gets a copy of each block, for the converter.
    var relabeled: AVAudioPCMBuffer?
    private var block = 0
    private(set) var failure: Int32?
    private(set) var unreadable = false

    init(input: AVAudioFile, buffer: AVAudioPCMBuffer, fault: ReadFault?) {
        self.input = input
        self.buffer = buffer
        self.fault = fault
    }

    /// False at the end of the file or after an error.
    func next() -> Bool {
        guard failure == nil, !unreadable, input.framePosition < input.length else { return false }
        defer { block += 1 }
        if let fault, fault.block == block {
            failure = fault.errno
            return false
        }
        do {
            try input.read(into: buffer, frameCount: buffer.frameCapacity)
        } catch {
            if let code = posixCode(of: error) { failure = code } else { unreadable = true }
            return false
        }
        return buffer.frameLength > 0
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
