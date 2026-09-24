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
        length: Frames
    ) throws {
        try session.addTrack(id, name: id.rawValue, layout: layout)
        try session.place(Clip(id: clip, file: file, start: start, offset: offset, length: length), on: id)
    }

    /// The mix of `range` from a new `MixReader`, as two channel arrays.
    func mix(_ range: Range<Frames>, session: Session? = nil) throws -> [[Float]] {
        let format = try #require(
            AVAudioFormat(standardFormatWithSampleRate: Double(self.session.sampleRate), channels: 2))
        let count = range.upperBound.count - range.lowerBound.count
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
        MixReader(package: url, session: session ?? self.session).render(range, into: buffer)
        return channels(buffer)
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
