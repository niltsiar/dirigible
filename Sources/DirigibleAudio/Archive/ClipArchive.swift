import AVFoundation
import AudioToolbox
import CryptoKit
import DirigibleCore
import Foundation

/// A step of one clip conversion (decision 0072). The test seam stops after a step as a crash does.
enum ClipArchiveStep: CaseIterable, Hashable, Sendable {
    /// The temporary file holds the whole target.
    case encoded
    /// The temporary file is on the disk.
    case flushed
    /// A full decode of the temporary file gives the samples of the source.
    case verified
    /// The temporary file has the target name, and `Clips/` is on the disk.
    case renamed
    /// The source is gone, and `Clips/` is on the disk.
    case removed
}

/// Why one clip conversion stopped. The source stays. Each path is relative to `Clips/`.
public enum ClipArchiveFault: Error, Hashable, Sendable {
    /// The path does not end in ".wav", or the WAV is not packed 24-bit integer PCM with the rate of
    /// the session and the channels of its pool entry.
    case notArchivable(path: String)
    /// A file at the target name holds other audio.
    case nameTaken(path: String)
    /// A decode fault of the source or of the new file, frames or an MD5 that differ, a source
    /// with fewer frames than its pool entry, or a status of the codec at a write of the new file.
    case mismatch(path: String)
    /// The errno of a write, a flush, a rename, or an unlink.
    case write(file: String, errno: Int32)
    /// The errno of a read of the disk.
    case read(file: String, errno: Int32)
}

/// WAV to FLAC: encodes to `.<name>.archive-<UUID>.tmp` with the Apple encoder, flushes it, decodes
/// it in full and compares the frames and the MD5 of the samples with the WAV and with STREAMINFO,
/// renames it to "<stem>.flac", flushes `Clips/`, checks the length and the byte size of the FLAC on
/// disk, unlinks the WAV, and flushes `Clips/`. With a FLAC already there (a crash after the rename),
/// it checks that FLAC and unlinks the WAV; a FLAC of other audio gives `.nameTaken`. Reads `isCancelled` before
/// each block: a stop removes the temporary file, keeps the WAV, and returns false. `after` is the
/// crash seam of tests: false stops after that step with no cleanup. Call it off the main actor,
/// under the package lock.
func archiveClip(
    _ file: AudioFile, in package: URL, rate: Int, isCancelled: () -> Bool = { false },
    after: (ClipArchiveStep, URL) -> Bool = { _, _ in true }
) throws(ClipArchiveFault) -> Bool {
    guard let flacPath = archivedPath(of: file.path) else { throw .notArchivable(path: file.path) }
    let clips = package.appending(path: clipsFolderName)
    let (wav, flac) = (clips.appending(path: file.path), clips.appending(path: flacPath))
    let (channels, frames) = (file.layout.channelCount, file.length.count)
    guard exists(wav) else {
        if exists(flac) { return true }
        throw .read(file: file.path, errno: ENOENT)
    }
    guard isArchivable(wav, rate: rate, channels: channels) else { throw .notArchivable(path: file.path) }

    if exists(flac) {
        let size = try byteSize(of: flac, name: flacPath)
        guard
            let source = try readPacked(wav, name: file.path, rate: rate, channels: channels, isCancelled: isCancelled),
            let same = try isFLAC(flac, of: source, name: flacPath, rate: rate, isCancelled: isCancelled)
        else { return false }
        guard same, source.frames >= frames else { throw .nameTaken(path: flacPath) }
        return try remove(wav, name: file.path, keeping: flac, frames: source.frames, size: size, after: after)
    }

    let temporary = flac.deletingLastPathComponent().appending(
        path: archiveTemporaryName(of: flac.lastPathComponent, UUID()))
    let source: (md5: Data, frames: Int)?
    do {
        let encoder = try FLACWriter(url: temporary, name: file.path, rate: rate, channels: channels)
        source = try readPacked(wav, name: file.path, rate: rate, channels: channels, isCancelled: isCancelled) {
            (list, count) throws(ClipArchiveFault) in try encoder.write(&list, frames: count)
        }
        try encoder.close()
    } catch {
        unlink(temporary.path)
        throw error
    }
    guard let source else {
        unlink(temporary.path)
        return false
    }
    guard after(.encoded, temporary) else { return false }
    let size = try flushNew(temporary, name: file.path)
    guard after(.flushed, temporary) else { return false }
    let same: Bool?
    do {
        same = try isFLAC(temporary, of: source, name: file.path, rate: rate, isCancelled: isCancelled)
    } catch {
        unlink(temporary.path)
        throw error
    }
    guard same == true, source.frames >= frames else {
        unlink(temporary.path)
        if same == nil { return false }
        throw .mismatch(path: file.path)
    }
    guard after(.verified, temporary) else { return false }
    try rename(temporary, to: flac, name: flacPath)
    guard after(.renamed, flac) else { return false }
    return try remove(wav, name: file.path, keeping: flac, frames: source.frames, size: size, after: after)
}

/// FLAC to WAV with `ClipWriter`, the writer of each clip WAV (the header of a Dirigible clip):
/// decodes to `.<name>.archive-<UUID>.tmp`, flushes it, compares the frames and the MD5 of its
/// samples with STREAMINFO, renames it to the pool path, flushes `Clips/`, checks the length and the
/// byte size of the WAV on disk, unlinks the FLAC, and flushes `Clips/`. With a WAV already there, it checks that WAV
/// against STREAMINFO and unlinks the FLAC; a WAV of other audio gives `.nameTaken`. Stops, the
/// seam, and the thread rule are those of `archiveClip`.
func unarchiveClip(
    _ file: AudioFile, in package: URL, rate: Int, isCancelled: () -> Bool = { false },
    after: (ClipArchiveStep, URL) -> Bool = { _, _ in true }
) throws(ClipArchiveFault) -> Bool {
    guard let flacPath = archivedPath(of: file.path) else { throw .notArchivable(path: file.path) }
    let clips = package.appending(path: clipsFolderName)
    let (wav, flac) = (clips.appending(path: file.path), clips.appending(path: flacPath))
    let (channels, frames) = (file.layout.channelCount, file.length.count)
    guard exists(flac) else {
        if exists(wav) { return true }
        throw .read(file: flacPath, errno: ENOENT)
    }
    guard let info = try streamInfo(of: flac, name: flacPath), info.bits == 24, info.frames >= frames,
        info.md5 != Data(count: 16)
    else { throw .mismatch(path: flacPath) }

    if exists(wav) {
        let size = try byteSize(of: wav, name: file.path)
        guard
            let source = try readPacked(wav, name: file.path, rate: rate, channels: channels, isCancelled: isCancelled)
        else { return false }
        guard source == (info.md5, info.frames), isArchivable(wav, rate: rate, channels: channels) else {
            throw .nameTaken(path: file.path)
        }
        return try remove(flac, name: flacPath, keeping: wav, frames: info.frames, size: size, after: after)
    }

    let temporary = wav.deletingLastPathComponent().appending(
        path: archiveTemporaryName(of: wav.lastPathComponent, UUID()))
    let written: (md5: Data, frames: Int)?
    let size: off_t
    do {
        guard
            try decode(
                flac, name: flacPath, into: temporary, targetName: file.path, rate: rate, channels: channels,
                isCancelled: isCancelled)
        else {
            unlink(temporary.path)
            return false
        }
        guard after(.encoded, temporary) else { return false }
        size = try flushNew(temporary, name: file.path)
        guard after(.flushed, temporary) else { return false }
        written = try readPacked(temporary, name: file.path, rate: rate, channels: channels, isCancelled: isCancelled)
    } catch {
        unlink(temporary.path)
        throw error
    }
    guard let written, written == (info.md5, info.frames), isArchivable(temporary, rate: rate, channels: channels)
    else {
        unlink(temporary.path)
        if written == nil { return false }
        throw .mismatch(path: flacPath)
    }
    guard after(.verified, temporary) else { return false }
    try rename(temporary, to: wav, name: file.path)
    guard after(.renamed, wav) else { return false }
    return try remove(flac, name: flacPath, keeping: wav, frames: info.frames, size: size, after: after)
}

/// The frames of each read and write block.
let blockFrames: UInt32 = 65_536

/// Packed 24-bit signed little-endian interleaved integers: the bytes of the WAV `data` chunk, and
/// the form of the STREAMINFO MD5 (RFC 9639 section 8.2).
func packed24(rate: Int, channels: Int) -> AudioStreamBasicDescription {
    let bytes = UInt32(3 * channels)
    return AudioStreamBasicDescription(
        mSampleRate: Double(rate), mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked, mBytesPerPacket: bytes,
        mFramesPerPacket: 1, mBytesPerFrame: bytes, mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 24,
        mReserved: 0)
}

/// True when an item is at `url`; a link counts.
func exists(_ url: URL) -> Bool {
    var info = stat()
    return lstat(url.path, &info) == 0
}

/// The byte size of the item at `url`, with no follow of a link.
func byteSize(of url: URL, name: String) throws(ClipArchiveFault) -> off_t {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { throw .read(file: name, errno: errno) }
    return info.st_size
}

/// True for a WAV of packed 24-bit integer PCM at `rate` with `channels`.
func isArchivable(_ url: URL, rate: Int, channels: Int) -> Bool {
    guard let file = try? AVAudioFile(forReading: url) else { return false }
    // The pointer lives only as long as its AVAudioFormat.
    let format = withExtendedLifetime(file.fileFormat) { $0.streamDescription.pointee }
    return format.mFormatID == kAudioFormatLinearPCM && format.mFormatFlags & kAudioFormatFlagIsFloat == 0
        && format.mBitsPerChannel == 24 && format.mBytesPerFrame == UInt32(3 * channels)
        && format.mChannelsPerFrame == UInt32(channels) && format.mSampleRate == Double(rate)
}

/// True when `url` is a FLAC whose STREAMINFO, full decode, and length on open give the frames and
/// the MD5 of `source`. Nil after a stop.
private func isFLAC(
    _ url: URL, of source: (md5: Data, frames: Int), name: String, rate: Int, isCancelled: () -> Bool
) throws(ClipArchiveFault) -> Bool? {
    guard let info = try streamInfo(of: url, name: name), info.bits == 24, info.frames == source.frames,
        info.md5 == source.md5
    else { return false }
    let channels = Int((try? AVAudioFile(forReading: url))?.fileFormat.channelCount ?? 0)
    guard channels > 0 else { return false }
    let decoded: (md5: Data, frames: Int)?
    do {
        decoded = try readPacked(url, name: name, rate: rate, channels: channels, isCancelled: isCancelled)
    } catch {
        guard case .mismatch = error else { throw error }
        return false
    }
    guard let decoded else { return nil }
    return decoded == source && (try? AVAudioFile(forReading: url).length) == AVAudioFramePosition(source.frames)
}

/// The bits per sample, the frame count, and the MD5 of the STREAMINFO block at the start of a FLAC
/// file (RFC 9639 sections 8.1 and 8.2), or nil when the file does not start with one.
private func streamInfo(of url: URL, name: String) throws(ClipArchiveFault) -> (bits: Int, frames: Int, md5: Data)? {
    let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
    guard descriptor >= 0 else { throw .read(file: name, errno: errno) }
    defer { close(descriptor) }
    var bytes = [UInt8](repeating: 0, count: 42)
    let count = pread(descriptor, &bytes, bytes.count, 0)
    guard count >= 0 else { throw .read(file: name, errno: errno) }
    // "fLaC", then the header of a STREAMINFO block (type 0) of 34 bytes.
    guard count == 42, Array(bytes[0..<8]) == [0x66, 0x4C, 0x61, 0x43, bytes[4] & 0x80, 0, 0, 34] else { return nil }
    let info = bytes[8...]
    let bits = (Int(info[20] & 0x01) << 4 | Int(info[21] >> 4)) + 1
    let frames = info[22..<26].reduce(Int(info[21] & 0x0F)) { $0 << 8 | Int($1) }
    return (bits, frames, Data(info[26..<42]))
}

/// Reads `url` in full as packed 24-bit samples, one block at a time: hashes each block and gives
/// it to `body`. Reads `isCancelled` before each block. Returns the MD5 and the frame count, or nil
/// after a stop. A decode fault is `.mismatch`, an I/O fault `.read`.
private func readPacked(
    _ url: URL, name: String, rate: Int, channels: Int, isCancelled: () -> Bool,
    body: (inout AudioBufferList, UInt32) throws(ClipArchiveFault) -> Void = { _, _ in }
) throws(ClipArchiveFault) -> (md5: Data, frames: Int)? {
    var reference: ExtAudioFileRef?
    let status = ExtAudioFileOpenURL(url as CFURL, &reference)
    guard status == noErr, let file = reference else { throw readFault(status, of: url, name: name) }
    defer { ExtAudioFileDispose(file) }
    var client = packed24(rate: rate, channels: channels)
    guard
        ExtAudioFileSetProperty(
            file, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout.size(ofValue: client)), &client) == noErr
    else { throw .mismatch(path: name) }
    let size = Int(blockFrames) * 3 * channels
    let data = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 4)
    defer { data.deallocate() }
    var list = AudioBufferList(
        mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: 0, mData: data))
    var hasher = Insecure.MD5()
    var total = 0
    while true {
        if isCancelled() { return nil }
        var frames = blockFrames
        list.mBuffers.mDataByteSize = UInt32(size)
        let status = ExtAudioFileRead(file, &frames, &list)
        guard status == noErr else { throw readFault(status, of: url, name: name) }
        if frames == 0 { break }
        hasher.update(bufferPointer: UnsafeRawBufferPointer(start: data, count: Int(frames) * 3 * channels))
        try body(&list, frames)
        total += Int(frames)
    }
    return (Data(hasher.finalize()), total)
}

/// `.read` when a POSIX read of every byte of `url` fails, else `.mismatch`: a codec status has no
/// errno (probe 2026-09-24).
private func readFault(_ status: OSStatus, of url: URL, name: String) -> ClipArchiveFault {
    let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
    guard descriptor >= 0 else { return .read(file: name, errno: errno) }
    defer { close(descriptor) }
    let error = NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    return ioErrno(of: error, file: descriptor).map { ClipArchiveFault.read(file: name, errno: $0) }
        ?? .mismatch(path: name)
}

/// Decodes the FLAC `source` into a new clip WAV at `target`; `targetName` names it in a write
/// fault. False after a stop.
private func decode(
    _ source: URL, name: String, into target: URL, targetName: String, rate: Int, channels: Int,
    isCancelled: () -> Bool
) throws(ClipArchiveFault) -> Bool {
    let descriptor = open(source.path, O_RDONLY | O_CLOEXEC)
    guard descriptor >= 0 else { throw .read(file: name, errno: errno) }
    defer { close(descriptor) }
    func fault(_ error: any Error) -> ClipArchiveFault {
        ioErrno(of: error, file: descriptor).map { ClipArchiveFault.read(file: name, errno: $0) }
            ?? .mismatch(path: name)
    }
    let input: AVAudioFile
    do { input = try AVAudioFile(forReading: source) } catch { throw fault(error) }
    guard input.fileFormat.sampleRate == Double(rate), Int(input.fileFormat.channelCount) == channels,
        let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: blockFrames)
    else { throw .mismatch(path: name) }
    // A status of the clip writer has no errno, so the FLAC stays and the job goes on.
    let writer: ClipWriter
    do { writer = try ClipWriter(url: target, file: targetName, format: input.processingFormat) } catch {
        throw .mismatch(path: name)
    }
    while input.framePosition < input.length {
        if isCancelled() { return false }
        do { try input.read(into: buffer, frameCount: blockFrames) } catch { throw fault(error) }
        guard buffer.frameLength > 0 else { throw .mismatch(path: name) }
        do { try writer.write(buffer) } catch { throw .mismatch(path: name) }
    }
    do { try writer.close() } catch { throw .mismatch(path: name) }
    return true
}
