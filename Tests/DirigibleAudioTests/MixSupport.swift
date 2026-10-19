import AVFoundation
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// A test ramp: frame `i` of channel `c` is a distinct multiple of 2^-23, so a 24-bit WAV holds it
/// exactly and a float32 read gives it back exactly. A wrong frame or a wrong channel shows.
func ramp(frames: Int, channel: Int = 0) -> [Float] {
    (0..<frames).map { i in Float(((i + channel * 3_000_001) * 7919) % 16_000_000 - 8_000_000) / 8_388_608 }
}

/// A package folder with a `Clips/` folder and a session that the test fills. No `session.xml`:
/// `MixReader` and `Player` read only the WAVs.
final class MixPackage {
    let folder: TemporaryFolder
    let url: URL
    var session: Session

    init(sampleRate: Int = 48_000) throws {
        folder = try TemporaryFolder()
        url = folder.url.appending(path: "Mix.dirigible")
        try FileManager.default.createDirectory(
            at: url.appending(path: clipsFolderName), withIntermediateDirectories: true)
        session = Session(sampleRate: sampleRate)
    }

    /// Writes a 24-bit WAV with the finalize writer and adds it to the pool.
    func addFile(_ id: FileID, channels: [[Float]], rate: Int? = nil) throws {
        let rate = rate ?? session.sampleRate
        let format = try #require(
            AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: AVAudioChannelCount(channels.count)))
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(channels[0].count)))
        buffer.frameLength = AVAudioFrameCount(channels[0].count)
        for (index, samples) in channels.enumerated() {
            buffer.floatChannelData![index].update(from: samples, count: samples.count)
        }
        let path = "\(id.rawValue).wav"
        let writer = try ClipWriter(url: url.appending(path: "\(clipsFolderName)/\(path)"), file: path, format: format)
        try writer.write(buffer)
        try writer.close()
        try session.addFile(
            AudioFile(
                id: id, path: path, layout: ChannelLayout(channelCount: channels.count)!,
                length: Frames(channels[0].count)))
    }

    /// Adds a track with one clip.
    func addTrack(
        _ id: TrackID, layout: ChannelLayout = .mono, clip: ClipID, file: FileID, start: Frames, offset: Frames,
        length: Frames, envelope: GainEnvelope = .empty
    ) throws {
        try session.addTrack(id, name: id.rawValue, layout: layout)
        try session.place(
            Clip(id: clip, file: file, start: start, offset: offset, length: length, envelope: envelope), on: id)
    }

    /// The mix of `range` from a new `MixReader`, as two channel arrays.
    func mix(_ range: Range<Frames>, session: Session? = nil) throws -> [[Float]] {
        try render(MixReader(package: url, session: session ?? self.session), range)
    }

    func reader() -> MixReader { MixReader(package: url, session: session) }

    func render(_ reader: MixReader, _ range: Range<Frames>) throws -> [[Float]] {
        let format = try #require(
            AVAudioFormat(standardFormatWithSampleRate: Double(self.session.sampleRate), channels: 2))
        let count = range.upperBound.count - range.lowerBound.count
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
        reader.render(range, into: buffer)
        return channels(buffer)
    }

    /// Cuts the WAV of `id` to `bytes` and returns the frames that `AVAudioFile` then gives (E6e).
    func truncate(_ id: FileID, toBytes bytes: UInt64) throws -> Int {
        let file = url.appending(path: "\(clipsFolderName)/\(id.rawValue).wav")
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: bytes)
        try handle.close()
        return Int(try AVAudioFile(forReading: file).length)
    }
}

/// The fades fixture (decision 0035): track t1 with a DC 0.25 clip at 0..<7000 and no fade, then
/// track t2 with a DC 0.5 clip "c1" at 1000, length 4800, fadeIn 480, and fadeOut 960. The plain
/// clip first in the chunk catches gain factors that scale the sum, not the clip.
func fadedPackage() throws -> MixPackage {
    let package = try MixPackage()
    try package.addFile("quarter", channels: [[Float](repeating: 0.25, count: 7000)])
    try package.addFile("half", channels: [[Float](repeating: 0.5, count: 4800)])
    try package.addTrack("t1", clip: "plain", file: "quarter", start: 0, offset: 0, length: 7000)
    try package.addTrack("t2", clip: "c1", file: "half", start: 1000, offset: 0, length: 4800)
    try package.session.setFades(["c1": #require(Fades(fadeIn: 480, fadeOut: 960))])
    return package
}

/// The expected fades fixture mix of `range`: 0.25 plus 0.5 * `Fades.gain` * `gain` in the clip.
func fadedMix(_ range: Range<Int>, gain: Double = 1) throws -> [Float] {
    let fades = try #require(Fades(fadeIn: 480, fadeOut: 960))
    return range.map { frame in
        let k = frame - 1000
        let faded = (0..<4800).contains(k) ? 0.5 * gain * fades.gain(at: Frames(k), length: 4800, curves: .sine) : 0
        return Float((frame < 7000 ? 0.25 : 0) + faded)
    }
}

/// The two channels of a float buffer.
func channels(_ buffer: AVAudioPCMBuffer) -> [[Float]] {
    (0..<Int(buffer.format.channelCount)).map {
        Array(UnsafeBufferPointer(start: buffer.floatChannelData![$0], count: Int(buffer.frameLength)))
    }
}

/// The largest absolute difference of two sample arrays; infinity when the counts differ.
func maxError(_ a: [Float], _ b: [Float]) -> Float {
    guard a.count == b.count else { return .infinity }
    return zip(a, b).map { abs($0 - $1) }.max() ?? 0
}

/// The frames `range` of each channel.
func slice(_ channels: [[Float]], _ range: Range<Int>) -> [[Float]] {
    channels.map { Array($0[range]) }
}

/// The crossfade fixture (decision 0036): stereo track t1 with clip A on a file of (1, 0) at
/// 1,000 ..< 11,000 and clip B on a file of (0, 1) at 11,000 ..< 21,000, each at offset 5,000 in a
/// file of 30,000 frames, with a crossfade of `length` at the join J = 11,000. The left channel is
/// A alone and the right channel B alone.
func crossfadedPackage(_ length: Int = 480) throws -> MixPackage {
    let package = try MixPackage()
    let (one, zero) = ([Float](repeating: 1, count: 30_000), [Float](repeating: 0, count: 30_000))
    try package.addFile("left", channels: [one, zero])
    try package.addFile("right", channels: [zero, one])
    try package.addTrack("t1", layout: .stereo, clip: "A", file: "left", start: 1_000, offset: 5_000, length: 10_000)
    try package.session.place(Clip(id: "B", file: "right", start: 11_000, offset: 5_000, length: 10_000), on: "t1")
    try package.session.setCrossfades(["A": Frames(length)])
    return package
}

/// The expected crossfade mix of `range`, in Double: over J - L/2 ..< J + L/2, with i = t - (J -
/// L/2), the left channel is sin(pi/2 * (L - i) / L) and the right channel sin(pi/2 * i / L).
func crossfadedMix(_ range: Range<Int>, length: Int = 480) -> [[Double]] {
    let first = 11_000 - length / 2
    let left = range.map { t -> Double in
        guard t >= 1_000 else { return 0 }
        return t < first
            ? 1 : t < 11_000 + length / 2 ? sin(.pi / 2 * Double(length - (t - first)) / Double(length)) : 0
    }
    let right = range.map { t -> Double in
        guard t < 21_000 else { return 0 }
        return t >= 11_000 + length / 2 ? 1 : t >= first ? sin(.pi / 2 * Double(t - first) / Double(length)) : 0
    }
    return [left, right]
}

/// The largest absolute difference of a rendered channel and a Double channel; infinity when the
/// counts differ.
func maxError(_ a: [Float], _ b: [Double]) -> Double {
    guard a.count == b.count else { return .infinity }
    return zip(a, b).map { abs(Double($0) - $1) }.max() ?? 0
}
