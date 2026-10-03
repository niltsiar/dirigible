import AVFoundation
import CLame
import Foundation

/// `lame_init` fills a global log table with no lock (`init_log_table` in `util.c`). This `let`
/// runs it once, before the first MP3 export, so two exports in two windows do not fill it at the
/// same time (decision 0034).
private let lameTables: Void = { _ = lame_close(lame_init()) }()

/// Writes an MP3 file through LAME (decision 0034): CBR at `bitRate`, `rate` Hz, and the channels
/// of `client`. LAME sets mono for one channel and joint stereo for two. It runs `body` with a
/// function that encodes one buffer of `client` frames, then flushes LAME and writes the LAME tag
/// frame at offset 0, so a decoder reads the exact length (probe U3; Core Audio reads one frame
/// more at 44.1 kHz with 96 or 160 kbit/s, probe len96). LAME changes the rate. It throws
/// `.rateNotSupported` when LAME does not keep the rate or the bit rate (probes U3 and U7).
///
/// Before the encode it clamps each sample in place to ±64 (+36 dBFS) and sets a NaN or an
/// infinite sample to 0: LAME aborts on an assert for a non-finite or very large sample (U8).
/// A write loops until all bytes are written; only a -1 return is a fault.
func writeMP3(
    _ url: URL, bitRate: BitRate, rate: Int, client: AVAudioFormat,
    _ body: ((AVAudioPCMBuffer) throws(ExportError) -> Void) throws(ExportError) -> Void
) throws(ExportError) {
    _ = lameTables
    guard let lame = lame_init() else { throw .writeFailed(kAudio_MemFullError) }
    defer { lame_close(lame) }
    let channels = Int(client.channelCount)
    lame_set_num_channels(lame, Int32(channels))
    lame_set_in_samplerate(lame, Int32(client.sampleRate))
    lame_set_out_samplerate(lame, Int32(rate))
    lame_set_brate(lame, Int32(bitRate.rawValue))
    lame_set_VBR(lame, vbr_off)
    lame_set_quality(lame, 3)
    // LAME lowers a rate or a bit rate that MPEG does not allow, and returns 0 (probes U3, U7).
    guard lame_init_params(lame) == 0, lame_get_out_samplerate(lame) == Int32(rate),
        lame_get_brate(lame) == Int32(bitRate.rawValue)
    else { throw .rateNotSupported(rate) }

    let descriptor = open(url.path, O_WRONLY | O_TRUNC | O_CLOEXEC)
    guard descriptor >= 0 else { throw writeFault(status: -40, errno: errno) }
    var open = true
    defer { if open { close(descriptor) } }
    // The LAME bound is 1.25 x the frames + 7200 bytes, after its rate change.
    let ratio = max(1, Double(rate) / client.sampleRate)
    var bytes = [UInt8](repeating: 0, count: 7200)
    func emit(_ count: Int32) throws(ExportError) {
        guard count >= 0 else { throw .writeFailed(OSStatus(count)) }
        try writeAll(descriptor, bytes, count: Int(count), at: nil)
    }
    try body { buffer throws(ExportError) in
        let frames = Int(buffer.frameLength)
        guard frames > 0, let data = buffer.floatChannelData else { return }
        for channel in 0..<channels {
            for index in 0..<frames {
                let x = data[channel][index]
                data[channel][index] = x.isFinite ? min(max(x, -64), 64) : 0
            }
        }
        let needed = Int(1.25 * Double(frames) * ratio) + 7200
        if bytes.count < needed { bytes = [UInt8](repeating: 0, count: needed) }
        let size = Int32(bytes.count)
        try emit(
            lame_encode_buffer_ieee_float(lame, data[0], channels == 2 ? data[1] : nil, Int32(frames), &bytes, size))
    }
    let size = Int32(bytes.count)
    try emit(lame_encode_flush(lame, &bytes, size))
    let tag = lame_get_lametag_frame(lame, &bytes, bytes.count)
    try writeAll(descriptor, bytes, count: tag, at: 0)
    open = false
    guard close(descriptor) == 0 else { throw writeFault(status: -40, errno: errno) }
}

/// Writes the first `count` of `bytes` at `offset`, or at the file position when it is nil.
/// A short write writes the rest; -1 maps through `writeFault`.
private func writeAll(_ descriptor: Int32, _ bytes: [UInt8], count: Int, at offset: off_t?) throws(ExportError) {
    var done = 0
    while done < count {
        let result = bytes.withUnsafeBytes { all in
            let start = all.baseAddress! + done
            return if let offset { pwrite(descriptor, start, count - done, offset + off_t(done)) } else {
                write(descriptor, start, count - done)
            }
        }
        guard result >= 0 else { throw writeFault(status: -40, errno: errno) }
        done += result
    }
}
