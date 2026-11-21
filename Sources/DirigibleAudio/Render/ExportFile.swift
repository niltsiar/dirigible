import AVFoundation
import AudioToolbox
import DirigibleCore

/// The file type and the file format of `format` at `rate` Hz with `channels` (probe P1). WAV
/// has the RF64 type, as `ClipWriter`: a plain RIFF WAV under 4 GiB and RF64 above it.
func fileDescription(_ format: ExportFormat, rate: Int, channels: UInt32) -> (
    AudioFileTypeID, AudioStreamBasicDescription
) {
    var description = AudioStreamBasicDescription()
    description.mSampleRate = Double(rate)
    description.mChannelsPerFrame = channels
    switch format {
    case .wav(let bits):
        let bytes = UInt32(bits.rawValue / 8)
        description.mFormatID = kAudioFormatLinearPCM
        description.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked
        description.mBitsPerChannel = UInt32(bits.rawValue)
        description.mBytesPerFrame = bytes * channels
        description.mBytesPerPacket = bytes * channels
        description.mFramesPerPacket = 1
        return (kAudioFileRF64Type, description)
    case .flac(let bits):
        description.mFormatID = kAudioFormatFLAC
        description.mFormatFlags =
            bits == .bits16 ? kAppleLosslessFormatFlag_16BitSourceData : kAppleLosslessFormatFlag_24BitSourceData
        return (kAudioFileFLACType, description)
    case .aac:
        description.mFormatID = kAudioFormatMPEG4AAC
        return (kAudioFileM4AType, description)
    case .mp3:
        preconditionFailure("MP3 goes through writeMP3")
    case .floatCAF:
        description.mFormatID = kAudioFormatLinearPCM
        description.mFormatFlags = kLinearPCMFormatFlagIsFloat | kLinearPCMFormatFlagIsPacked
        description.mBitsPerChannel = 32
        description.mBytesPerFrame = 4 * channels
        description.mBytesPerPacket = 4 * channels
        description.mFramesPerPacket = 1
        return (kAudioFileCAFType, description)
    }
}

/// Makes the file of `format` at `rate` Hz with the channels of `client`, runs `body` with a
/// function that writes one buffer of `client` frames, and closes the file. MP3 goes through
/// `writeMP3`, with `tag` (the ID3 tag, decision 0045) at the file start. Each other format goes through `ExtAudioFile`, with `client` as the client format
/// (the converter changes the rate, probe P4) and the AAC bit rate (P5).
func writeFile(
    _ url: URL, format: ExportFormat, rate: Int, client: AVAudioFormat, tag: [UInt8] = [],
    _ body: ((AVAudioPCMBuffer) throws(ExportError) -> Void) throws(ExportError) -> Void
) throws(ExportError) {
    if case .mp3(let bitRate) = format {
        return try writeMP3(url, bitRate: bitRate, rate: rate, client: client, tag: tag, body)
    }
    var (type, description) = fileDescription(format, rate: rate, channels: client.channelCount)
    var created: ExtAudioFileRef?
    let status = ExtAudioFileCreateWithURL(
        url as CFURL, type, &description, nil, AudioFileFlags.eraseFile.rawValue, &created)
    guard status == noErr, let file = created else { throw .writeFailed(status) }
    do throws(ExportError) {
        var clientDescription = client.streamDescription.pointee
        try check(
            ExtAudioFileSetProperty(
                file, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout.size(ofValue: clientDescription)),
                &clientDescription))
        if case .aac(let bitRate) = format { try setBitRate(bitRate, of: file) }
        try body { buffer throws(ExportError) in
            let status = ExtAudioFileWrite(file, buffer.frameLength, buffer.audioBufferList)
            guard status == noErr else { throw writeFault(status: status, errno: errno) }
        }
    } catch {
        ExtAudioFileDispose(file)
        throw error
    }
    // The close writes the header sizes and the last packets, so its status counts.
    let closed = ExtAudioFileDispose(file)
    guard closed == noErr else { throw writeFault(status: closed, errno: errno) }
}

/// The error of a failed write: -40 with errno ENOSPC is a full disk (probe P8). -40 with
/// another errno (EIO for a lost volume, P8b) and any other status is `.writeFailed`.
func writeFault(status: OSStatus, errno code: Int32) -> ExportError {
    status == -40 && code == ENOSPC ? .diskFull : .writeFailed(status)
}

/// Sets `kAudioConverterEncodeBitRate` of the converter of `file`, then a nil converter
/// configuration, so the file takes the change.
private func setBitRate(_ bitRate: BitRate, of file: ExtAudioFileRef) throws(ExportError) {
    var converter: AudioConverterRef?
    var size = UInt32(MemoryLayout<AudioConverterRef?>.size)
    try check(ExtAudioFileGetProperty(file, kExtAudioFileProperty_AudioConverter, &size, &converter))
    guard let converter else { throw .writeFailed(kAudio_ParamError) }
    var bitsPerSecond = UInt32(bitRate.rawValue * 1000)
    try check(AudioConverterSetProperty(converter, kAudioConverterEncodeBitRate, 4, &bitsPerSecond))
    var configuration: CFPropertyList?
    try check(
        withUnsafePointer(to: &configuration) {
            ExtAudioFileSetProperty(
                file, kExtAudioFileProperty_ConverterConfig, UInt32(MemoryLayout<CFPropertyList?>.size), $0)
        })
}

private func check(_ status: OSStatus) throws(ExportError) {
    guard status == noErr else { throw .writeFailed(status) }
}
