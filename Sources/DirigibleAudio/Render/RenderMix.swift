import AVFoundation
import AudioToolbox
import DirigibleCore
import Foundation

public enum RenderError: Error, Hashable, Sendable {
    /// An item is at the output path. It did not change.
    case exists
    /// The CAF write gave this status.
    case writeFailed(OSStatus)
    /// The move to the output path gave this errno.
    case moveFailed(Int32)
}

/// Renders the mix of `range` to a 32-bit float stereo CAF at the session rate (decision 0016),
/// the call of `dirigible render`. It renders `chunk` frames at a time into one reused buffer,
/// so the memory does not grow with the range. It writes `.<name>.<UUID>.tmp` in the folder of
/// `url`, then moves it with `renamex_np(RENAME_EXCL)`, which never replaces an item. Where that
/// gives ENOTSUP or EPERM (exFAT, probe X1), it claims `url` with `O_CREAT | O_EXCL`, then
/// renames over the claim. Every exit removes the temporary file; a throw also removes its own
/// claim. At the start it removes the leftovers of a render to `url` that died. Returns the
/// faults of the files that the range reads.
public func renderMix(
    _ session: Session, package: URL, range: Range<Frames>, to url: URL, chunk: Int = 48_000
) throws(RenderError) -> [FileID: MediaFault] {
    guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(session.sampleRate), channels: 2),
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk))
    else { throw .writeFailed(kAudio_ParamError) }
    removeRenderLeftovers(of: url)
    let temporary = url.deletingLastPathComponent().appending(path: "\(leftoverPrefix(url))\(UUID().uuidString).tmp")
    defer { unlink(temporary.path) }
    let mix = MixReader(package: package, session: session)
    try writeCAF(temporary, format: format) { file throws(RenderError) in
        var start = range.lowerBound
        while start < range.upperBound {
            let end = min(start + Frames(chunk), range.upperBound)
            mix.render(start..<end, into: buffer)
            let status = ExtAudioFileWrite(file, buffer.frameLength, buffer.audioBufferList)
            guard status == noErr else { throw .writeFailed(status) }
            start = end
        }
    }
    try move(temporary, to: url)
    return mix.faults
}

/// Removes the temporary files of the renders to `url`: `.<name>.<UUID>.tmp` in the folder of
/// `url`. A render that died (a kill, a crash) leaves one. `dirigible render` also calls it at
/// SIGINT. A name with no UUID stays: the render did not make it.
public func removeRenderLeftovers(of url: URL) {
    let folder = url.deletingLastPathComponent()
    let prefix = leftoverPrefix(url)
    for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    where name.hasPrefix(prefix) && name.hasSuffix(".tmp")
        && UUID(uuidString: String(name.dropFirst(prefix.count).dropLast(4))) != nil
    {
        unlink(folder.appending(path: name).path)
    }
}

private func leftoverPrefix(_ url: URL) -> String { ".\(url.lastPathComponent)." }

/// Makes a float CAF with the channels of `format`, runs `body`, and closes the file.
private func writeCAF(
    _ url: URL, format: AVAudioFormat, _ body: (ExtAudioFileRef) throws(RenderError) -> Void
) throws(RenderError) {
    let channels = format.channelCount
    var fileFormat = AudioStreamBasicDescription(
        mSampleRate: format.sampleRate, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kLinearPCMFormatFlagIsFloat | kLinearPCMFormatFlagIsPacked, mBytesPerPacket: 4 * channels,
        mFramesPerPacket: 1, mBytesPerFrame: 4 * channels, mChannelsPerFrame: channels, mBitsPerChannel: 32,
        mReserved: 0)
    var created: ExtAudioFileRef?
    var status = ExtAudioFileCreateWithURL(
        url as CFURL, kAudioFileCAFType, &fileFormat, nil, AudioFileFlags.eraseFile.rawValue, &created)
    guard status == noErr, let file = created else { throw .writeFailed(status) }
    var client = format.streamDescription.pointee
    status = ExtAudioFileSetProperty(
        file, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout.size(ofValue: client)), &client)
    do throws(RenderError) {
        guard status == noErr else { throw .writeFailed(status) }
        try body(file)
    } catch {
        ExtAudioFileDispose(file)
        throw error
    }
    // The close writes the header sizes, so its status counts.
    status = ExtAudioFileDispose(file)
    guard status == noErr else { throw .writeFailed(status) }
}

/// Moves `source` to `target` and never replaces an item there (probe X1).
private func move(_ source: URL, to target: URL) throws(RenderError) {
    guard renamex_np(source.path, target.path, UInt32(RENAME_EXCL)) != 0 else { return }
    guard errno == ENOTSUP || errno == EPERM else { throw errno == EEXIST ? .exists : .moveFailed(errno) }
    let claim = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
    guard claim >= 0 else { throw errno == EEXIST ? .exists : .moveFailed(errno) }
    close(claim)
    guard rename(source.path, target.path) == 0 else {
        let code = errno
        unlink(target.path)
        throw .moveFailed(code)
    }
}
