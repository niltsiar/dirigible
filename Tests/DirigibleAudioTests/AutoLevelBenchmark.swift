import AVFoundation
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// Run 8b criterion 5: the stop wait. `autoLevel` with `.equallyPerTrack` (the stop mode) on 4
/// clips of 2 h on 4 mono tracks takes 5.0 s or less in an optimized build (`make bench
/// FILTER=AutoLevelBenchmark`). The 4 clips read one shared 24-bit WAV of 1.04 GB, warm, because
/// the disk has little free space (U2). A serial loop takes about 9.1 s.
struct AutoLevelBenchmark {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func fourTwoHourClipsWithinBudget() throws {
        let package = try MixPackage()
        let wav = package.url.appending(path: "\(clipsFolderName)/f1.wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536))
        buffer.frameLength = 65_536
        buffer.floatChannelData![0].update(from: tone([(65_536.0 / 48_000, -30)], layout: .mono)[0], count: 65_536)
        let writer = try ClipWriter(url: wav, file: "f1.wav", format: format)
        // 5 274 x 65 536 frames = 7 200.4 s.
        let blocks = 5_274
        for _ in 0..<blocks { try writer.write(buffer) }
        try writer.close()
        let length = Frames(blocks * 65_536)
        try package.session.addFile(AudioFile(id: "f1", path: "f1.wav", layout: .mono, length: length))
        let clips: [ClipID] = ["c1", "c2", "c3", "c4"]
        for (index, clip) in clips.enumerated() {
            try package.addTrack(
                TrackID("t\(index + 1)"), clip: clip, file: "f1", start: 0, offset: 0, length: length)
        }
        // Warm the cache, as the stop reads WAVs that the finalize just wrote.
        let handle = try FileHandle(forReadingFrom: wav)
        while let data = try handle.read(upToCount: 1 << 24), !data.isEmpty {}
        try handle.close()

        let clock = ContinuousClock()
        let start = clock.now
        let (_, levels) = autoLevel(Set(clips), .equallyPerTrack, of: package.session, in: package.url)
        let elapsed = clock.now - start

        print("bench report: 4 clips of 2 h took \(elapsed)")
        let leveled = levels.values.filter { if case .leveled = $0 { true } else { false } }.count
        #expect(leveled == 4, "levels: \(levels)")
        expectWithinBudget(elapsed, .seconds(5), "4 clips of 2 h took \(elapsed)")
    }
}
