import AVFoundation
import DirigibleCore
import Foundation
import Testing
import os

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

    /// Code gate 1 item 1: an online-only item is refused before its first read.
    @Test func anItemThatIsNotDownloadedIsRefused() throws {
        let package = try ImportPackage(tracks: [("t1", .mono)])
        let source = package.source("Voice.wav")
        try writeSource(source, .wav16, rate: 48_000, channels: [ramp(frames: 4_800)])

        #expect(throws: ImportError.notDownloaded(file: "Voice.wav"), "an item that is not downloaded refuses") {
            try DirigibleAudio.importAudio(
                source, to: ImportTarget(track: "t1", start: 0), of: package.session, in: package.url,
                freeBytes: { .max }, isDownloaded: { _ in false })
        }
        #expect(package.clipsNames == [])
        #expect(isDownloaded(ubiquitous: true, status: .notDownloaded) == false, "the cloud rule refuses it")
        for (ubiquitous, status) in [
            (nil, nil), (false, nil), (true, .current), (true, .downloaded), (true, nil),
        ] as [(Bool?, URLUbiquitousItemDownloadingStatus?)] {
            #expect(isDownloaded(ubiquitous: ubiquitous, status: status), "\(String(describing: status))")
        }
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
        let (reads, box) = (OSAllocatedUnfairLock(initialState: 0), OSAllocatedUnfairLock(initialState: [Double]()))

        #expect(throws: ImportError.cancelled) {
            try importAudio(
                source, to: ImportTarget(track: "t1", start: 0), of: package.session, in: package.url,
                progress: { value in box.withLock { $0.append(value) } },
                isCancelled: {
                    reads.withLock { reads in
                        reads += 1
                        return reads >= 2
                    }
                })
        }
        #expect(box.withLock { $0.count } == 1, "the import ends before the second block")
        #expect(package.clipsNames == [], "the cancel leaves no temporary file")
    }

    @Test func aCancelInTheSecondPassLeavesNoFile() throws {
        let package = try ImportPackage(tracks: [("t1", .mono)])
        let source = package.source("Tail.wav")
        try writeSource(source, .wav16, rate: 44_100, channels: [loudTail(frames: 3 * 65_536)])
        let box = OSAllocatedUnfairLock(initialState: [Double]())

        #expect(throws: ImportError.cancelled) {
            try importAudio(
                source, to: ImportTarget(track: "t1", start: 0), of: package.session, in: package.url,
                progress: { value in box.withLock { $0.append(value) } },
                isCancelled: { box.withLock { $0.last ?? 0 > 0.5 } })
        }
        let values = box.withLock { $0 }
        #expect(values.filter { $0 > 0.5 }.count == 1, "the second pass ends after the flag: \(values)")
        #expect(package.clipsNames == [], "the cancel leaves no temporary file")
    }

    /// A cancel after the rename removes the WAV (decision 0049): no session names it.
    @Test func aCancelAfterTheRenameRemovesTheWAV() throws {
        let package = try ImportPackage(tracks: [("t1", .mono)])
        let source = package.source("Voice.wav")
        try writeSource(source, .wav16, rate: 48_000, channels: [sine(seconds: 1, rate: 48_000)])
        let wav = package.clip("Voice.wav")
        let renamed = OSAllocatedUnfairLock(initialState: false)

        #expect(throws: ImportError.cancelled, "a cancel after the rename throws") {
            try importAudio(
                source, to: ImportTarget(track: "t1", start: 0), of: package.session, in: package.url,
                isCancelled: {
                    renamed.withLock { seen in
                        seen = seen || FileManager.default.fileExists(atPath: wav.path)
                        return seen
                    }
                })
        }
        #expect(renamed.withLock { $0 }, "the rename happened")
        #expect(package.clipsNames == [], "the WAV goes")
    }

    /// C4: a cancel in the level step stops the level at its next block and removes the WAV. The
    /// conversion gives 0...0.8 and the level 0.8...1; the source of 3 s is three level blocks.
    @Test func aCancelInTheLevelStepRemovesTheWAV() throws {
        let package = try ImportPackage(tracks: [("t1", .mono)])
        let source = package.source("Voice.wav")
        try writeSource(source, .wav16, rate: 48_000, channels: [sine(seconds: 3, rate: 48_000)])
        let box = OSAllocatedUnfairLock(initialState: [Double]())

        #expect(throws: ImportError.cancelled) {
            try importAudio(
                source, to: ImportTarget(track: "t1", start: 0), of: package.session, in: package.url,
                progress: { value in box.withLock { $0.append(value) } },
                isCancelled: { box.withLock { $0.last ?? 0 > 0.8 } })
        }
        let values = box.withLock { $0 }
        #expect(values.filter { $0 > 0.8 }.count == 1, "the level ends at the block after the flag: \(values)")
        #expect(package.clipsNames == [], "the WAV goes")
    }

    /// C4: a flush fault after the rename keeps the WAV as an unused file (decision 0040). With
    /// `Clips/` at mode 0300, the WAV is made and renamed, but the folder does not open to flush.
    @Test func aFlushFaultKeepsTheWAV() throws {
        let package = try ImportPackage(tracks: [("t1", .mono)])
        let source = package.source("Voice.wav")
        try writeSource(source, .wav16, rate: 48_000, channels: [sine(seconds: 1, rate: 48_000)])
        let clips = package.url.appending(path: clipsFolderName)
        try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
        chmod(clips.path, 0o300)
        defer { chmod(clips.path, 0o755) }

        var thrown: ImportError?
        do throws(ImportError) {
            _ = try importAudio(
                source, to: ImportTarget(track: "t1", start: 0), of: package.session, in: package.url,
                freeBytes: { .max })
        } catch {
            thrown = error
        }
        chmod(clips.path, 0o755)
        guard case .write(_, .writeFailed(let file, _))? = thrown else {
            Issue.record("not a flush fault: \(String(describing: thrown))")
            return
        }
        #expect(file == clipsFolderName, "the flush of Clips/ failed")
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

    /// C3 (decision 0056): an import never replaces a file in `Clips/`. Another file at the name
    /// during the conversion: the import throws a write fault with EEXIST, that file keeps its
    /// bytes, and no temp stays.
    @Test func anImportNeverReplacesAWAV() throws {
        let package = try ImportPackage(tracks: [("t1", .mono)])
        let source = package.source("Voice.wav")
        try writeSource(source, .wav16, rate: 48_000, channels: [sine(seconds: 1, rate: 48_000)])
        try FileManager.default.createDirectory(
            at: package.url.appending(path: clipsFolderName), withIntermediateDirectories: true)
        let (wav, other) = (package.clip("Voice.wav"), Data("another file".utf8))

        #expect(throws: ImportError.write(file: "Voice.wav", .writeFailed(file: "Clips/Voice.wav", status: EEXIST))) {
            try importAudio(
                source, to: ImportTarget(track: "t1", start: 0), of: package.session, in: package.url, level: false,
                progress: { _ in if !FileManager.default.fileExists(atPath: wav.path) { try? other.write(to: wav) } })
        }
        #expect(FileManager.default.contents(atPath: wav.path) == other, "the other file keeps its bytes")
        #expect(package.clipsNames == ["Voice.wav"], "no temp stays")
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
