import AVFoundation
import DirigibleCore
import Foundation
import Testing
import os

@testable import DirigibleAudio

/// A paste from a package of another sample rate converts, as an import does (decision 0042, C10).
/// P44 is at 44 100 Hz: track t1 with file take1-mic (176 400 frames, an impulse at frame 22 050),
/// clip A (0, length 88 200, fade-in 441) and clip B (at 88 200, offset 90 000, length 44 100),
/// with a crossfade of 882 frames at their join. Q is at 48 000 Hz with mono track u1.
struct PasteConvertTests {
    let p: MixPackage
    let q: MixPackage

    init() throws {
        p = try MixPackage(sampleRate: 44_100)
        q = try MixPackage()
        try p.addFile("take1-mic", channels: [impulse(176_400, at: 22_050)])
        try p.addTrack("t1", clip: "A", file: "take1-mic", start: 0, offset: 0, length: 88_200)
        try p.session.place(Clip(id: "B", file: "take1-mic", start: 88_200, offset: 90_000, length: 44_100), on: "t1")
        try p.session.setFades(["A": Fades(fadeIn: 441, fadeOut: 0)!])
        try p.session.setCrossfades(["A": 882])
        try q.session.addTrack("u1", name: "u1", layout: .mono)
        FileManager.default.createFile(atPath: p.url.appending(path: ".lock").path, contents: nil)
    }

    var clipboard: Clipboard {
        get throws {
            Clipboard(
                try p.session.excerpt(of: 0..<132_300, on: ["t1"]), package: p.url, origin: PackageID(lockFileOf: p.url)
            )
        }
    }

    func names() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: q.url.appending(path: clipsFolderName).path).sorted()
    }

    func paste(
        free: Int64 = .max, progress: @escaping (Double) -> Void = { _ in },
        isCancelled: @escaping () -> Bool = { false }
    ) throws(PasteError) -> (session: Session, clips: [ClipID], tracks: [TrackID]) {
        try pasteClipboard(
            try! clipboard, from: p.url, into: q.session, in: q.url, identity: nil, mode: .over(at: 480_000),
            on: .tracks(["u1"]),
            freeBytes: { free }, progress: progress, isCancelled: isCancelled)
    }

    /// C12: a Replace at another rate pastes at the range start, and the later audio moves by the
    /// converted clipboard length (132 300 frames at 44.1 kHz give 144 000) minus the range length.
    @Test func aReplaceStartsAtTheRangeStart() throws {
        try q.addFile("later", channels: [[Float](repeating: 0, count: 48_000)])
        try q.session.place(Clip(id: "L", file: "later", start: 600_000, offset: 0, length: 48_000), on: "u1")

        let (session, clips, _) = try pasteClipboard(
            try clipboard, from: p.url, into: q.session, in: q.url, identity: nil, mode: .replace(480_000..<528_000),
            on: .tracks(["u1"]), freeBytes: { .max })

        #expect(session.clip(clips[0])?.clip.start == 480_000, "the first clip is at the range start")
        #expect(session.clip("L")?.clip.start == 696_000, "600 000 + 144 000 - 48 000")
    }

    /// C10 and C10c: a 24-bit WAV at 48 kHz, the clips scaled by edges, renamed before the return.
    @Test func anotherSampleRateConvertsTheFileAndScalesTheClips() throws {
        let (session, clips, _) = try paste()

        #expect(try names() == ["take1-mic.wav"], "one new file, no .tmp")
        let wav = try ImportedWAV(q.url.appending(path: "\(clipsFolderName)/take1-mic.wav"))
        #expect(wav.rate == 48_000 && wav.bits == 24 && wav.channels.count == 1)
        #expect(abs(wav.frames - 192_000) <= 1 && abs(wav.peakFrame - 24_000) <= 1)
        #expect(session.files["take1-mic"]?.length == Frames(wav.frames), "the record has the converted length")
        let a = try #require(session.clip(clips[0])?.clip)
        let b = try #require(session.clip(clips[1])?.clip)
        #expect(a.start == 480_000 && a.offset == 0 && a.length == 96_000 && a.fades.fadeIn == 480)
        #expect(b.start == 576_000 && b.offset == 97_959 && b.length == 48_000 && a.end == b.start)
        #expect(a.crossfades.end == 960 && b.crossfades.start == 960 && a.gain == .zero)
        #expect(!FileManager.default.fileExists(atPath: q.url.appending(path: "session.xml").path))
    }

    /// C10b: the progress never goes down and ends at 1; a cancel at the first call changes nothing.
    @Test func aConvertedPasteReportsProgressAndCancelChangesNothing() throws {
        let values = OSAllocatedUnfairLock<[Double]>(initialState: [])
        _ = try paste(progress: { value in values.withLock { $0.append(value) } })
        let seen = values.withLock { $0 }
        #expect(seen.count > 2 && zip(seen, seen.dropFirst()).allSatisfy { $0 <= $1 } && seen.last == 1)

        let r = try MixPackage()
        try r.session.addTrack("u1", name: "u1", layout: .mono)
        let called = OSAllocatedUnfairLock(initialState: false)
        #expect(throws: PasteError.cancelled) {
            try pasteClipboard(
                try clipboard, from: p.url, into: r.session, in: r.url, identity: nil, mode: .over(at: 0),
                on: .tracks(["u1"]),
                freeBytes: { .max }, progress: { _ in called.withLock { $0 = true } },
                isCancelled: { called.withLock { $0 } })
        }
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: r.url.appending(path: clipsFolderName).path).isEmpty)
    }

    /// C10c: a cancel after the conversion and before the renames leaves no WAV.
    @Test func aCancelBeforeTheRenamesLeavesNoWAV() throws {
        let done = OSAllocatedUnfairLock(initialState: false)
        #expect(throws: PasteError.cancelled) {
            try paste(
                progress: { value in if value >= 1 { done.withLock { $0 = true } } },
                isCancelled: { done.withLock { $0 } })
        }
        #expect(try names().isEmpty, "no WAV and no .tmp")
    }

    /// C10d: the converted bytes and the margin, with no clone exception.
    @Test func theSpaceCheckOfAConversionCountsTheNewBytes() throws {
        let needed = Int64(192_000 * 3) + diskMargin

        #expect(throws: PasteError.space(needed: needed, free: needed - 1)) { try paste(free: needed - 1) }
        #expect(try names().isEmpty)
        _ = try paste(free: needed)
        #expect(try names() == ["take1-mic.wav"])
    }

    /// C3 (decision 0056): the second target name is taken during the conversions. The first WAV
    /// stays, the other file keeps its bytes, and no temp is left.
    @Test func aRenameFaultKeepsTheFirstFile() throws {
        try p.addFile("take2-mic", channels: [impulse(44_100, at: 0)])
        try p.session.place(Clip(id: "C", file: "take2-mic", start: 132_300, offset: 0, length: 44_100), on: "t1")
        let clipboard = Clipboard(try p.session.excerpt(of: 0..<176_400, on: ["t1"]), package: p.url, origin: nil)
        let (taken, other) = (q.url.appending(path: "\(clipsFolderName)/take2-mic.wav"), Data("another file".utf8))

        #expect(throws: PasteError.write(file: "take2-mic.wav", errno: EEXIST)) {
            try pasteClipboard(
                clipboard, from: p.url, into: q.session, in: q.url, identity: nil, mode: .over(at: 480_000),
                on: .tracks(["u1"]),
                freeBytes: { .max },
                progress: { _ in if !FileManager.default.fileExists(atPath: taken.path) { try? other.write(to: taken) }
                })
        }
        #expect(FileManager.default.contents(atPath: taken.path) == other, "the other file keeps its bytes")
        #expect(try names() == ["take1-mic.wav", "take2-mic.wav"], "the first WAV stays, no temp is left")
    }
}

/// Code gate 1 item 3: the session edit runs again with the real converted lengths, which can be
/// 1 frame off the prediction; and a frame count that does not divide gives records that equal
/// the WAV frame counts.
struct PasteConvertLengthTests {
    @Test(arguments: [-1, 1])
    func aPlanWithTheRealLengthsFitsTheFiles(delta: Int) throws {
        let fixture = try PasteConvertTests()
        let excerpt = try fixture.p.session.excerpt(of: 0..<132_300, on: ["t1"])
        let length = Frames(192_000 + delta)

        let plan = try PastePlan(
            excerpt, same: false, into: fixture.q.session, in: fixture.q.url, mode: .over(at: 480_000),
            on: .tracks(["u1"]),
            lengths: ["take1-mic": length], gains: [:], stems: ["take1-mic": "take1-mic"])

        #expect(plan.session.files["take1-mic"]?.length == length, "the record has the real length")
        let clips = plan.clips.compactMap { plan.session.clip($0)?.clip }
        #expect(clips.count == 2 && clips.allSatisfy { $0.offset + $0.length <= length }, "each clip fits its file")
    }

    @Test func aFrameCountThatDoesNotDivideGivesTheWAVLength() throws {
        let p = try MixPackage(sampleRate: 44_100)
        let q = try MixPackage()
        try p.addFile("odd", channels: [impulse(176_406, at: 22_050)])
        try p.addTrack("t1", clip: "A", file: "odd", start: 0, offset: 0, length: 176_406)
        try q.session.addTrack("u1", name: "u1", layout: .mono)
        let clipboard = Clipboard(try p.session.excerpt(of: 0..<176_406, on: ["t1"]), package: p.url, origin: nil)

        let (session, clips, _) = try pasteClipboard(
            clipboard, from: p.url, into: q.session, in: q.url, identity: nil, mode: .over(at: 0), on: .tracks(["u1"]),
            freeBytes: { .max })

        let wav = try ImportedWAV(q.url.appending(path: "\(clipsFolderName)/odd.wav"))
        #expect(
            session.files["odd"]?.length == Frames(wav.frames),
            "record \(String(describing: session.files["odd"]?.length)), WAV \(wav.frames)")
        let clip = try #require(session.clip(clips[0])?.clip)
        #expect(clip.offset + clip.length <= Frames(wav.frames))
    }
}

/// Code gate 2 nit: the space check of a conversion counts the frames of the file, which the
/// conversion reads in full, not the frames of a shorter record.
struct PasteConvertSpaceTests {
    @Test func theSpaceCheckCountsTheFramesOfTheFile() throws {
        let p = try MixPackage(sampleRate: 44_100)
        let q = try MixPackage()
        try p.addFile("long", channels: [impulse(176_400, at: 22_050)])
        var session = Session(sampleRate: 44_100)
        try session.addFile(AudioFile(id: "long", path: "long.wav", layout: .mono, length: 88_200))
        try session.addTrack("t1", name: "t1", layout: .mono)
        try session.place(Clip(id: "A", file: "long", start: 0, offset: 0, length: 88_200), on: "t1")
        try q.session.addTrack("u1", name: "u1", layout: .mono)
        let clipboard = Clipboard(try session.excerpt(of: 0..<88_200, on: ["t1"]), package: p.url, origin: nil)
        let (byRecord, byFile) = (Int64(96_000 * 3) + diskMargin, Int64(192_000 * 3) + diskMargin)

        #expect(throws: PasteError.space(needed: byFile, free: byRecord)) {
            try pasteClipboard(
                clipboard, from: p.url, into: q.session, in: q.url, identity: nil, mode: .over(at: 0),
                on: .tracks(["u1"]),
                freeBytes: { byRecord })
        }
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: q.url.appending(path: clipsFolderName).path).isEmpty)
    }
}
