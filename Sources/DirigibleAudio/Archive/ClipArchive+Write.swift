import AVFoundation
import AudioToolbox
import DirigibleCore
import Foundation

/// Releases the blocks that the codec allocated past the end of a new file, then flushes the file
/// to the disk. On APFS a truncate to the same size keeps those blocks, and a truncate one byte up
/// and back releases them (probe 2026-11-25: up to 16 MB after a file over 64 MB).
func flushNew(_ url: URL, name: String) throws(ClipArchiveFault) {
    let descriptor = open(url.path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
    var info = stat()
    let code: Int32? =
        if descriptor < 0 {
            errno
        } else if fstat(descriptor, &info) != 0 || ftruncate(descriptor, info.st_size + 1) != 0
            || ftruncate(descriptor, info.st_size) != 0
        {
            errno
        } else {
            fullFlush(descriptor)
        }
    if descriptor >= 0 { close(descriptor) }
    if let code {
        unlink(url.path)
        throw .write(file: name, errno: code)
    }
}

/// Moves the checked temporary file to its name, never over an item, and flushes the folder.
func rename(_ temporary: URL, to target: URL, name: String) throws(ClipArchiveFault) {
    do throws(ExportError) {
        try moveNew(temporary, to: target)
    } catch {
        unlink(temporary.path)
        if case .moveFailed(let code) = error { throw .write(file: name, errno: code) }
        throw .nameTaken(path: name)
    }
    if let code = fullFlush(path: target.deletingLastPathComponent().path) { throw .write(file: name, errno: code) }
}

/// Unlinks the source after a check that the target on disk opens with `frames`, then flushes the folder.
func remove(
    _ source: URL, name: String, keeping target: URL, frames: Int, after: (ClipArchiveStep, URL) -> Bool
) throws(ClipArchiveFault) -> Bool {
    guard (try? AVAudioFile(forReading: target).length) == AVAudioFramePosition(frames) else {
        throw .mismatch(path: name)
    }
    guard unlink(source.path) == 0 else { throw .write(file: name, errno: errno) }
    if let code = fullFlush(path: source.deletingLastPathComponent().path) { throw .write(file: name, errno: code) }
    return after(.removed, target)
}

/// A new FLAC file through `ExtAudioFile` with the Apple encoder, 24-bit source data, and the packed
/// 24-bit client format (run unknown U20).
final class FLACWriter {
    private var file: ExtAudioFileRef?
    private let name: String

    init(url: URL, name: String, rate: Int, channels: Int) throws(ClipArchiveFault) {
        self.name = name
        // The claim never follows a link and never takes an item that is there.
        let claim = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard claim >= 0 else { throw .write(file: name, errno: errno) }
        Darwin.close(claim)
        var format = AudioStreamBasicDescription()
        format.mSampleRate = Double(rate)
        format.mFormatID = kAudioFormatFLAC
        format.mFormatFlags = UInt32(kAppleLosslessFormatFlag_24BitSourceData)
        format.mChannelsPerFrame = UInt32(channels)
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var status = AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, 0, nil, &size, &format)
        guard status == noErr else { throw .write(file: name, errno: status) }
        status = ExtAudioFileCreateWithURL(
            url as CFURL, kAudioFileFLACType, &format, nil, AudioFileFlags.eraseFile.rawValue, &file)
        guard status == noErr, let file else { throw .write(file: name, errno: status) }
        var client = packed24(rate: rate, channels: channels)
        status = ExtAudioFileSetProperty(
            file, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout.size(ofValue: client)), &client)
        guard status == noErr else { throw .write(file: name, errno: status) }
    }

    deinit {
        if let file { ExtAudioFileDispose(file) }
    }

    func write(_ list: inout AudioBufferList, frames: UInt32) throws(ClipArchiveFault) {
        guard let file else { return }
        let status = ExtAudioFileWrite(file, frames, &list)
        guard status == noErr else { throw .write(file: name, errno: status) }
    }

    /// Writes STREAMINFO and closes the file.
    func close() throws(ClipArchiveFault) {
        guard let file else { return }
        self.file = nil
        let status = ExtAudioFileDispose(file)
        guard status == noErr else { throw .write(file: name, errno: status) }
    }
}
