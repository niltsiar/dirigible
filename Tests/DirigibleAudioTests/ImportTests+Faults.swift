import AVFoundation
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// C5: a failed import adds no name to `Clips/`, also no temporary file.
struct ImportFaultTests {
    @Test func aTextFileIsNotAudio() throws {
        let package = try ImportPackage(tracks: [("t1", .mono)])
        let source = package.source("notes.mp3")
        try Data("hello world".utf8).write(to: source)

        #expect(throws: ImportError.notAudio(file: "notes.mp3"), "a text file is not audio") {
            try importAudio(source, to: ImportTarget(track: "t1", start: 0), of: package.session, in: package.url)
        }
        #expect(package.clipsNames == [])
    }

    @Test func aSixChannelFileIsRefused() throws {
        let package = try ImportPackage()
        let source = package.source("Surround.wav")
        try writePCM16WAV(source, channels: 6, frames: 4_800)

        #expect(throws: ImportError.tooManyChannels(file: "Surround.wav", channels: 6), "6 channels refuse") {
            try importAudio(source, to: ImportTarget(track: nil, start: 0), of: package.session, in: package.url)
        }
        #expect(package.clipsNames == [])
    }

    /// One second of mono at the session rate needs 48,000 x 3 bytes and the 1 GB margin.
    @Test func theDiskCheckRefusesOneByteLess() throws {
        let package = try ImportPackage(tracks: [("t1", .mono)])
        let source = package.source("Second.wav")
        try writeSource(source, .wav16, rate: 48_000, channels: [ramp(frames: 48_000)])
        let needed: Int64 = 48_000 * 3 + 1_000_000_000

        #expect(throws: ImportError.space(file: "Second.wav", needed: needed, free: needed - 1), "1 byte less refuses")
        {
            try importAudio(
                source, to: ImportTarget(track: "t1", start: 0), of: package.session, in: package.url,
                freeBytes: { needed - 1 })
        }
        #expect(package.clipsNames == [], "a refusal makes no file")
        let imported = try? importAudio(
            source, to: ImportTarget(track: "t1", start: 0), of: package.session, in: package.url,
            freeBytes: { needed })
        #expect(imported != nil, "the exact need passes")
    }

    @Test func aCancelAtTheSecondBlockLeavesNoFile() throws {
        let package = try ImportPackage(tracks: [("t1", .mono)])
        let source = package.source("Long.wav")
        try writeSource(source, .wav16, rate: 44_100, channels: [sine(seconds: 4, rate: 44_100)])
        var (reads, values) = (0, [Double]())

        #expect(throws: ImportError.cancelled) {
            try importAudio(
                source, to: ImportTarget(track: "t1", start: 0), of: package.session, in: package.url,
                progress: { values.append($0) },
                isCancelled: {
                    reads += 1
                    return reads >= 2
                })
        }
        #expect(values.count == 1, "the import ends before the second block")
        #expect(package.clipsNames == [], "the cancel leaves no temporary file")
    }

    @Test func aCancelInTheSecondPassLeavesNoFile() throws {
        let package = try ImportPackage(tracks: [("t1", .mono)])
        let source = package.source("Tail.wav")
        try writeSource(source, .wav16, rate: 44_100, channels: [loudTail(frames: 3 * 65_536)])
        var values: [Double] = []

        #expect(throws: ImportError.cancelled) {
            try importAudio(
                source, to: ImportTarget(track: "t1", start: 0), of: package.session, in: package.url,
                progress: { values.append($0) }, isCancelled: { values.last ?? 0 > 0.5 })
        }
        #expect(values.filter { $0 > 0.5 }.count == 1, "the second pass ends after the flag: \(values)")
        #expect(package.clipsNames == [], "the cancel leaves no temporary file")
    }

    /// A cancel after the rename skips the level and keeps the WAV as an unused file: the caller
    /// can have a session that names it (decision 0040).
    @Test func aCancelAfterTheRenameSkipsTheLevel() throws {
        let package = try ImportPackage(tracks: [("t1", .mono)])
        let source = package.source("Voice.wav")
        try writeSource(source, .wav16, rate: 48_000, channels: [sine(seconds: 1, rate: 48_000)])
        let wav = package.clip("Voice.wav")

        #expect(throws: ImportError.cancelled, "a cancel after the rename throws") {
            try importAudio(
                source, to: ImportTarget(track: "t1", start: 0), of: package.session, in: package.url,
                isCancelled: { FileManager.default.fileExists(atPath: wav.path) })
        }
        #expect(package.clipsNames == ["Voice.wav"], "the WAV stays")
    }

    @Test func aClipsFolderWithNoWriteAccessIsAWriteFault() throws {
        let package = try ImportPackage(tracks: [("t1", .mono)])
        let source = package.source("Voice.wav")
        try writeSource(source, .wav16, rate: 48_000, channels: [ramp(frames: 4_800)])
        let clips = package.url.appending(path: clipsFolderName)
        try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: clips.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: clips.path) }

        let error = #expect(throws: ImportError.self) {
            try importAudio(source, to: ImportTarget(track: "t1", start: 0), of: package.session, in: package.url)
        }
        guard case .write(let file, .writeFailed)? = error else {
            Issue.record("not a write fault: \(String(describing: error))")
            return
        }
        #expect(file == "Voice.wav")
        #expect(package.clipsNames == [])
    }

    @Test func aBadTargetConvertsNothing() throws {
        let package = try ImportPackage(tracks: [("t1", .mono)])
        let source = package.source("Voice.wav")
        try writeSource(source, .wav16, rate: 48_000, channels: [ramp(frames: 4_800)])

        #expect(throws: ImportError.session(.unknownTrack("nope"))) {
            try importAudio(source, to: ImportTarget(track: "nope", start: 0), of: package.session, in: package.url)
        }
        #expect(throws: ImportError.session(.frameOutOfRange)) {
            try importAudio(source, to: ImportTarget(track: "t1", start: -1), of: package.session, in: package.url)
        }
        #expect(package.clipsNames == [])
    }
}

/// A 16-bit PCM WAV of silence with `channels` channels at 48 kHz, written byte by byte, so a
/// channel count with no standard layout is possible.
func writePCM16WAV(_ url: URL, channels: Int, frames: Int) throws {
    var data = Data()
    func append<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    let bytes = frames * channels * 2
    data.append(contentsOf: Array("RIFF".utf8))
    append(UInt32(36 + bytes))
    data.append(contentsOf: Array("WAVEfmt ".utf8))
    append(UInt32(16))
    append(UInt16(1))
    append(UInt16(channels))
    append(UInt32(48_000))
    append(UInt32(48_000 * channels * 2))
    append(UInt16(channels * 2))
    append(UInt16(16))
    data.append(contentsOf: Array("data".utf8))
    append(UInt32(bytes))
    data.append(Data(count: bytes))
    try data.write(to: url)
}
