import AudioToolbox
import DirigibleCore
import Foundation

enum CaptureError: Error, Hashable, Sendable {
    /// A segment file cannot be made, written, flushed, or closed. `status` is an OSStatus or
    /// an errno.
    case writeFailed(file: String, status: Int32)

    var status: Int32 {
        switch self {
        case .writeFailed(_, let status): status
        }
    }
}

/// One segment on disk: `<stem>.caf` (float32, interleaved, at the header rate) and
/// `<stem>.sidecar` (decision 0012). The writes are synchronous, so the kernel has every frame
/// that `write` accepted, and a crash of the process loses none (decision 0004). The CAF data
/// size stays "to the end of the file" until `close`. Use it on one queue only.
final class SegmentWriter {
    private let caf: URL
    private let sidecar: URL
    private let bytesPerFrame: Int
    private var audioFile: AudioFileID?
    private var sidecarDescriptor: Int32
    private var cafDescriptor: Int32
    private var byteOffset: Int64 = 0

    /// Writes and flushes the magic and the header before it makes the CAF, so a CAF with frames
    /// always has a header.
    init(folder: URL, name: SegmentName, header: CaptureHeader) throws(CaptureError) {
        caf = folder.appending(path: "\(name.stem).caf")
        sidecar = folder.appending(path: "\(name.stem).sidecar")
        bytesPerFrame = 4 * header.channelCount

        sidecarDescriptor = open(sidecar.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
        cafDescriptor = -1
        guard sidecarDescriptor >= 0 else { throw .writeFailed(file: sidecar.lastPathComponent, status: errno) }
        try append(Sidecar.encode(header))
        try Self.flush(sidecarDescriptor, file: sidecar)

        var format = AudioStreamBasicDescription(
            mSampleRate: header.nominalRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: UInt32(bytesPerFrame),
            mFramesPerPacket: 1, mBytesPerFrame: UInt32(bytesPerFrame), mChannelsPerFrame: UInt32(header.channelCount),
            mBitsPerChannel: 32, mReserved: 0)
        let status = AudioFileCreateWithURL(
            caf as CFURL, kAudioFileCAFType, &format, .eraseFile, &audioFile)
        guard status == noErr else { throw .writeFailed(file: caf.lastPathComponent, status: status) }
        // AudioFile has no flush call; a second descriptor flushes the same file.
        cafDescriptor = open(caf.path, O_RDONLY | O_CLOEXEC)
        guard cafDescriptor >= 0 else { throw .writeFailed(file: caf.lastPathComponent, status: errno) }
        // The folder entries of both files, so a power loss cannot lose flushed frames.
        if let code = fullFlush(path: folder.path) { throw .writeFailed(file: folder.lastPathComponent, status: code) }
    }

    deinit {
        if let audioFile { AudioFileClose(audioFile) }
        if sidecarDescriptor >= 0 { Darwin.close(sidecarDescriptor) }
        if cafDescriptor >= 0 { Darwin.close(cafDescriptor) }
    }

    /// Appends `frames` interleaved frames to the CAF.
    func write(_ interleaved: UnsafeBufferPointer<Float>, frames: Int) throws(CaptureError) {
        precondition(interleaved.count * 4 >= frames * bytesPerFrame, "The buffer holds the frames")
        guard let audioFile, frames > 0, let base = interleaved.baseAddress else { return }
        var size = UInt32(frames * bytesPerFrame)
        let status = AudioFileWriteBytes(audioFile, false, byteOffset, &size, base)
        guard status == noErr else { throw .writeFailed(file: caf.lastPathComponent, status: status) }
        byteOffset += Int64(size)
    }

    /// Appends one checkpoint record with one `write` call.
    func checkpoint(_ checkpoint: Checkpoint) throws(CaptureError) {
        try append(Sidecar.encode(checkpoint))
    }

    /// `F_FULLFSYNC` on both files, or `fsync` where the volume refuses it.
    func flush() throws(CaptureError) {
        try Self.flush(sidecarDescriptor, file: sidecar)
        try Self.flush(cafDescriptor, file: caf)
    }

    /// Closes both files and flushes them. The CAF gets its data size.
    func close() throws(CaptureError) {
        guard let audioFile else { return }
        self.audioFile = nil
        let status = AudioFileClose(audioFile)
        // After AudioFileClose, so the data size that it writes is on the disk too.
        let flushed = Result { () throws(CaptureError) in try flush() }
        Darwin.close(sidecarDescriptor)
        Darwin.close(cafDescriptor)
        sidecarDescriptor = -1
        cafDescriptor = -1
        guard status == noErr else { throw .writeFailed(file: caf.lastPathComponent, status: status) }
        try flushed.get()
    }

    private func append(_ data: Data) throws(CaptureError) {
        let written = data.withUnsafeBytes { Darwin.write(sidecarDescriptor, $0.baseAddress, $0.count) }
        guard written == data.count else {
            throw .writeFailed(file: sidecar.lastPathComponent, status: written < 0 ? errno : ENOSPC)
        }
    }

    private static func flush(_ descriptor: Int32, file: URL) throws(CaptureError) {
        if let code = fullFlush(descriptor) { throw .writeFailed(file: file.lastPathComponent, status: code) }
    }
}
