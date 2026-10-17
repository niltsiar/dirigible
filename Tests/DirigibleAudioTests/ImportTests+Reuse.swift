import DirigibleCore
import Foundation
import Testing
import os

@testable import DirigibleAudio

/// The reuse of a pool file with the same bytes (agent-pack C10 to C13, decision 0040).
struct ImportReuseTests {
    /// The bytes of a file, or nil.
    func bytes(_ url: URL) -> Data? { FileManager.default.contents(atPath: url.path) }

    /// C10: a rate change and the level give the same WAV again (probe P1), so the second import
    /// adds a clip on the first file.
    @Test func aSecondImportOfOneFileReusesItsWAV() throws {
        let package = try ImportPackage(tracks: [("t1", .mono)])
        let source = package.source("Talk.wav")
        try writeSource(source, .wav16, rate: 44_100, channels: [sine(seconds: 2, rate: 44_100)])
        let first = try importAudio(
            source, to: ImportTarget(track: "t1", start: 0), of: package.session, in: package.url)
        let wav = bytes(package.clip("Talk.wav"))

        let second = try importAudio(
            source, to: ImportTarget(track: "t1", start: 192_000), of: first.session, in: package.url)

        #expect(second.clip == "Talk 2", "the clip ID follows the stem rule")
        let clip = try #require(second.session.clip(second.clip)?.clip)
        #expect(clip.file == "Talk" && clip.start == 192_000, "the clip is on the first file: \(clip)")
        #expect(clip.length == first.session.files["Talk"]?.length, "the clip takes the whole file")
        #expect(second.session.files.keys.sorted() == ["Talk"], "no new pool file")
        #expect(package.clipsNames == ["Talk.wav"], "no new item in Clips/: \(package.clipsNames)")
        #expect(bytes(package.clip("Talk.wav")) == wav, "the reuse changed the WAV")
    }

    /// C11: another layout, or one other sample, makes a new file.
    @Test func anImportOfOtherAudioMakesANewFile() throws {
        let package = try ImportPackage(tracks: [("stereo", .stereo), ("mono", .mono)])
        let (left, right) = (ramp(frames: 70_000), ramp(frames: 70_000, channel: 1))
        var changed = right
        changed[69_999] = 0
        try writeSource(package.source("Two.wav"), .wav24, rate: 48_000, channels: [left, right])
        try writeSource(package.source("Edit.wav"), .wav24, rate: 48_000, channels: [left, changed])

        let stereo = try importAudio(
            package.source("Two.wav"), to: ImportTarget(track: "stereo", start: 0), of: package.session,
            in: package.url, level: false)
        let mono = try importAudio(
            package.source("Two.wav"), to: ImportTarget(track: "mono", start: 0), of: stereo.session,
            in: package.url, level: false)
        let edit = try importAudio(
            package.source("Edit.wav"), to: ImportTarget(track: "stereo", start: 96_000), of: mono.session,
            in: package.url, level: false)

        let files = edit.session.files
        #expect(files.keys.sorted() == ["Edit", "Two", "Two 2"], "\(files.keys.sorted())")
        #expect(files["Edit"]?.length == files["Two"]?.length, "Two was a candidate of the same length")
        #expect(package.clipsNames == ["Edit.wav", "Two 2.wav", "Two.wav"], "\(package.clipsNames)")
        #expect(edit.session.clip(mono.clip)?.clip.file == "Two 2" && edit.session.clip(edit.clip)?.clip.file == "Edit")
    }

    /// C12b: the compare reads the flag at each block of 65,536 frames. The pool WAV has 4 blocks of
    /// data; the flag turns true after the first compared block.
    @Test func aCancelDuringTheReuseCompareStopsAtTheNextBlock() throws {
        let package = try ImportPackage(tracks: [("t1", .mono)])
        let source = package.source("Same.wav")
        try writeSource(source, .wav24, rate: 48_000, channels: [ramp(frames: 4 * 65_536)])
        let first = try importAudio(
            source, to: ImportTarget(track: "t1", start: 0), of: package.session, in: package.url, level: false)
        let wav = bytes(package.clip("Same.wav"))
        let box = OSAllocatedUnfairLock(initialState: (values: [Double](), flipped: ContinuousClock.Instant?.none))

        #expect(throws: ImportError.cancelled) {
            try importAudio(
                source, to: ImportTarget(track: "t1", start: 0), of: first.session, in: package.url, level: false,
                progress: { value in
                    box.withLock { state in
                        state.values.append(value)
                        if value > 0.9, state.flipped == nil { state.flipped = .now }
                    }
                }, isCancelled: { box.withLock { $0.flipped != nil } })
        }
        let (values, flipped) = box.withLock { ($0.values, $0.flipped) }
        if let flipped { print("U20: the cancel of the compare ended \(flipped.duration(to: .now)) after the flag") }
        let compared = values.filter { $0 > 0.9 }
        #expect(compared.count == 1 && compared[0] < 1, "the compare ends at the block after the flag: \(values)")
        #expect(package.clipsNames == ["Same.wav"], "a cancelled compare left \(package.clipsNames)")
        #expect(bytes(package.clip("Same.wav")) == wav, "the cancel changed the pool WAV")
    }

    /// C12b: the conversion gives 0...0.7, the compare 0.7...0.8, and the level 0.8...1; with no
    /// level, 0...0.9 and 0.9...1. With no candidate, the progress steps over the compare share.
    @Test func theReuseCompareReportsProgress() throws {
        let package = try ImportPackage(tracks: [("t1", .mono)])
        let source = package.source("Same.wav")
        try writeSource(source, .wav24, rate: 48_000, channels: [ramp(frames: 4 * 65_536)])
        func values(_ session: Session, level: Bool) throws -> (Session, [Double]) {
            let box = OSAllocatedUnfairLock(initialState: [Double]())
            let imported = try importAudio(
                source, to: ImportTarget(track: "t1", start: 0), of: session, in: package.url, level: level,
                progress: { value in box.withLock { $0.append(value) } })
            return (imported.session, box.withLock { $0 })
        }
        func rising(_ list: [Double]) -> Bool { zip(list, list.dropFirst()).allSatisfy { $0 <= $1 } }

        let (first, none) = try values(package.session, level: true)
        let (second, leveled) = try values(first, level: true)
        let (_, unleveled) = try values(second, level: false)

        #expect(rising(none) && none.last == 1, "\(none)")
        #expect(!none.contains { $0 > 0.7 && $0 < 0.8 }, "no candidate steps over the compare share: \(none)")
        #expect(rising(leveled) && leveled.last == 1, "\(leveled)")
        let compare = leveled.filter { $0 > 0.7 && $0 < 0.8 }
        #expect(compare.count >= 3, "the compare of 4 blocks reports in 0.7...0.8: \(leveled)")
        #expect(leveled.contains { $0 > 0.8 && $0 < 1 }, "the level reports in 0.8...1: \(leveled)")
        #expect(rising(unleveled) && unleveled.last == 1, "\(unleveled)")
        #expect(unleveled.filter { $0 > 0.9 && $0 < 1 }.count >= 3, "with no level, 0.9...1: \(unleveled)")
    }

    /// C13: a pool file with missing or short media, and the file of a capture, are never a reuse
    /// target, also with the same bytes.
    @Test func anImportReusesOnlyAReadablePoolFile() throws {
        let made = try ImportPackage(tracks: [("t1", .mono)])
        let source = made.source("Voice.wav")
        try writeSource(source, .wav24, rate: 48_000, channels: [ramp(frames: 100_000)])
        let length = try #require(
            try importAudio(
                source, to: ImportTarget(track: "t1", start: 0), of: made.session, in: made.url, level: false
            ).session.files["Voice"]?.length)
        let wav = try #require(bytes(made.clip("Voice.wav")))
        let package = try ImportPackage(tracks: [("t1", .mono)])
        try FileManager.default.createDirectory(at: package.clip(""), withIntermediateDirectories: true)
        try wav.write(to: package.clip("Take.wav"))
        try wav.prefix(wav.count - 3).write(to: package.clip("Short.wav"))
        try package.session.addCapture(
            Capture(
                id: CaptureID("Take"), deviceUID: "usb-1", deviceName: "USB Mic", hostTimeNanos: 0, sampleTime: 0,
                nominalSampleRate: 48_000, measuredSampleRate: 48_000, latency: 0))
        let pool: [(String, CaptureID?)] = [("Take", "Take"), ("Short", nil), ("Missing", nil)]
        for (id, capture) in pool {
            try package.session.addFile(
                AudioFile(id: FileID(id), path: "\(id).wav", layout: .mono, length: length, capture: capture))
        }

        let imported = try importAudio(
            source, to: ImportTarget(track: "t1", start: 0), of: package.session, in: package.url, level: false)

        #expect(imported.session.clip(imported.clip)?.clip.file == "Voice", "the import made its own file")
        #expect(package.clipsNames == ["Short.wav", "Take.wav", "Voice.wav"], "\(package.clipsNames)")
        #expect(bytes(package.clip("Voice.wav")) == wav, "the made WAV has the bytes of the take")
        #expect(bytes(package.clip("Take.wav")) == wav && bytes(package.clip("Short.wav")) == wav.prefix(wav.count - 3))
    }

    /// The open descriptors of the files under `folder`: the entries of `/dev/fd` whose path is
    /// there. Other tests run at the same time, so a count of all entries would not be exact.
    func openFiles(under folder: URL) -> Int {
        guard let root = realpath(folder.path, nil) else { return -1 }
        defer { free(root) }
        let prefix = String(cString: root) + "/"
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd")) ?? []
        return entries.compactMap { Int32($0) }.filter { descriptor in
            var path = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
            guard fcntl(descriptor, F_GETPATH, &path) == 0 else { return false }
            return String(decoding: path.prefix { $0 != 0 }, as: UTF8.self).hasPrefix(prefix)
        }.count
    }

    /// Code gate 1 item 1: an import with no candidate, and an import that reuses a file, close
    /// each descriptor that they open. A leak holds the made WAV open after the rename.
    @Test func anImportClosesEachFileThatItOpens() throws {
        let package = try ImportPackage(tracks: [("t1", .mono)])
        let source = package.source("Talk.wav")
        try writeSource(source, .wav16, rate: 48_000, channels: [sine(seconds: 1, rate: 48_000)])
        let before = openFiles(under: package.folder.url)

        let first = try autoreleasepool {
            try importAudio(
                source, to: ImportTarget(track: "t1", start: 0), of: package.session, in: package.url, level: false)
        }
        #expect(openFiles(under: package.folder.url) == before, "the import with no candidate")
        let second = try autoreleasepool {
            try importAudio(
                source, to: ImportTarget(track: "t1", start: 96_000), of: first.session, in: package.url,
                level: false)
        }
        #expect(openFiles(under: package.folder.url) == before, "the import that reuses a file")
        #expect(before == 0 && second.session.files.keys.sorted() == ["Talk"], "the second import is a reuse")
    }
}

/// The reuse in `Studio` (agent-pack C14).
@MainActor
struct StudioImportReuseTests {
    /// C14: the Undo of a reused import keeps the WAV and the first clip, and no peak pass starts.
    @Test func theUndoOfAReusedImportKeepsTheFile() async throws {
        let fixture = try await ImportStudioFixture.make()
        let cache = try TemporaryFolder()
        let studio = try await fixture.open(peakCache: cache.url)
        _ = try await studio.importAudio(fixture.source, to: ImportTarget(track: "t1", start: 96_000)) { _ in }
        #expect(await waitForPeaks(studio, "Voice") != nil, "the peaks of the first import load")
        await until(limit: .seconds(30), "the peak pass of the first import runs") { studio.peakLoad.pass == nil }
        let (session, peaks) = (studio.session, studio.peaks)
        let wav = fixture.url.appending(path: "\(clipsFolderName)/Voice.wav")
        let bytes = FileManager.default.contents(atPath: wav.path)

        let clip = try await studio.importAudio(fixture.source, to: ImportTarget(track: "t1", start: 500_000)) { _ in }

        #expect(studio.session.clip(clip)?.clip.file == "Voice" && studio.session.files == session.files, "a reuse")
        #expect(studio.peakLoad.pass == nil, "the reuse started a peak pass")
        try studio.undo()
        #expect(studio.session == session, "Undo gives back the session of the first import")
        #expect(studio.peakLoad.pass == nil && studio.peaks == peaks, "the Undo started a peak pass")
        let kept = FileManager.default.contents(atPath: wav.path) == bytes
        #expect(
            kept && fixture.clipsNames == ["Voice.wav", "f1.wav"], "the Undo changed Clips/: \(fixture.clipsNames)")
    }
}
