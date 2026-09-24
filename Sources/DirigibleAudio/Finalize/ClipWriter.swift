import AVFoundation
import AudioToolbox

/// The 24-bit WAV output of finalize (decision 0012). `ExtAudioFile` with the RF64 file type
/// writes a plain RIFF WAV under 4 GiB and RF64 over it. It reports a status for each write and
/// for the close; `AVAudioFile.close()` returns void. It never seeks the write position.
final class ClipWriter {
    static let fileType = kAudioFileRF64Type

    private var file: ExtAudioFileRef?
    private let name: String

    /// `format` is the client format: float32, non-interleaved, at the session rate. `name` is
    /// the package-relative path for errors.
    init(url: URL, file name: String, format: AVAudioFormat) throws(FinalizeError) {
        self.name = name
        let channels = format.channelCount
        var fileFormat = AudioStreamBasicDescription(
            mSampleRate: format.sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 3 * channels, mFramesPerPacket: 1, mBytesPerFrame: 3 * channels,
            mChannelsPerFrame: channels, mBitsPerChannel: 24, mReserved: 0)
        var status = ExtAudioFileCreateWithURL(
            url as CFURL, Self.fileType, &fileFormat, nil, AudioFileFlags.eraseFile.rawValue, &file)
        guard status == noErr, let file else { throw .writeFailed(file: name, status: status) }
        var client = format.streamDescription.pointee
        status = ExtAudioFileSetProperty(
            file, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout.size(ofValue: client)), &client)
        guard status == noErr else { throw .writeFailed(file: name, status: status) }
    }

    deinit {
        if let file { ExtAudioFileDispose(file) }
    }

    func write(_ buffer: AVAudioPCMBuffer) throws(FinalizeError) {
        guard let file, buffer.frameLength > 0 else { return }
        let status = ExtAudioFileWrite(file, buffer.frameLength, buffer.audioBufferList)
        guard status == noErr else { throw .writeFailed(file: name, status: status) }
    }

    /// Writes the header sizes and closes the file.
    func close() throws(FinalizeError) {
        guard let file else { return }
        self.file = nil
        let status = ExtAudioFileDispose(file)
        guard status == noErr else { throw .writeFailed(file: name, status: status) }
    }
}
