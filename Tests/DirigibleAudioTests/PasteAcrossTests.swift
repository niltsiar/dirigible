import AVFoundation
import DirigibleCore
import Foundation
import Testing
import os

@testable import DirigibleAudio

/// A paste from another package (decision 0042). P has mono tracks t1 and t2, files take1-mic
/// (192 000 frames, 440 Hz) and take2-mic (96 000 frames, 220 Hz), clips A and B of take1-mic on t1
/// and C of take2-mic on t2. Q has mono tracks u1 and u2 and its own take1-mic (48 000 frames of
/// silence) with clip Z on u2. So the file ID take1-mic names other audio in each package (0004).
struct PasteAcrossTests {
    let p: MixPackage
    let q: MixPackage

    init() throws {
        p = try MixPackage()
        q = try MixPackage()
        try p.addFile("take1-mic", channels: [sine(seconds: 4, rate: 48_000, frequency: 440)])
        try p.addFile("take2-mic", channels: [sine(seconds: 2, rate: 48_000, frequency: 220)])
        try p.addTrack("t1", clip: "A", file: "take1-mic", start: 0, offset: 0, length: 96_000)
        try p.session.place(Clip(id: "B", file: "take1-mic", start: 96_000, offset: 96_000, length: 48_000), on: "t1")
        try p.addTrack("t2", clip: "C", file: "take2-mic", start: 0, offset: 0, length: 96_000)
        try q.addFile("take1-mic", channels: [[Float](repeating: 0, count: 48_000)])
        try q.session.addTrack("u1", name: "u1", layout: .mono)
        try q.addTrack("u2", clip: "Z", file: "take1-mic", start: 0, offset: 0, length: 48_000)
        for package in [p, q] {
            FileManager.default.createFile(atPath: package.url.appending(path: ".lock").path, contents: nil)
        }
    }

    var clipboard: Clipboard {
        get throws {
            Clipboard(
                try p.session.excerpt(of: 0..<192_000, on: ["t1", "t2"]), package: p.url,
                origin: PackageID(lockFileOf: p.url))
        }
    }

    func names(_ package: MixPackage) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: package.url.appending(path: clipsFolderName).path).sorted()
    }

    func bytes(_ package: MixPackage, _ name: String) -> Data? {
        FileManager.default.contents(atPath: package.url.appending(path: "\(clipsFolderName)/\(name)").path)
    }

    func paste(
        _ clipboard: Clipboard, on target: PasteTarget = .tracks(["u1", "u2"]), identity: PackageID? = nil,
        free: Int64 = .max, canClone: @escaping (URL, URL) -> Bool = { cloneWorks($0, into: $1) },
        isCancelled: @escaping () -> Bool = { false }
    ) throws(PasteError) -> (session: Session, clips: [ClipID], tracks: [TrackID]) {
        try pasteClipboard(
            clipboard, from: clipboard.package, into: q.session, in: q.url,
            identity: identity ?? PackageID(lockFileOf: q.url), at: 480_000, on: target, freeBytes: { free },
            canClone: canClone, isCancelled: isCancelled)
    }

    @Test func aPasteCopiesEachFileOnceUnderANewID() throws {
        let zBefore = bytes(q, "take1-mic.wav")

        let (session, clips, tracks) = try paste(try clipboard)

        #expect(try names(q) == ["take1-mic 2.wav", "take1-mic.wav", "take2-mic.wav"], "two copies, no .tmp")
        #expect(bytes(q, "take1-mic 2.wav") == bytes(p, "take1-mic.wav"), "the copy of P's take1-mic")
        #expect(bytes(q, "take2-mic.wav") == bytes(p, "take2-mic.wav"))
        #expect(bytes(q, "take1-mic.wav") == zBefore, "Q's own file does not change")
        #expect(
            session.files["take1-mic 2"]
                == AudioFile(id: "take1-mic 2", path: "take1-mic 2.wav", layout: .mono, length: 192_000))
        #expect(
            session.files["take2-mic"]?.length == 96_000 && session.files["take1-mic"] == q.session.files["take1-mic"])
        #expect(clips == ["A@480000", "B@576000", "C@480000"] && tracks == ["u1", "u2"])
        let a = try #require(session.clip("A@480000")?.clip)
        #expect(a.file == "take1-mic 2" && a.offset == 0 && a.length == 96_000)
        #expect(session.clip("B@576000")?.clip.offset == 96_000 && session.clip("C@480000")?.clip.file == "take2-mic")
        #expect(session.clip("Z")?.clip == q.session.clip("Z")?.clip, "clip Z does not change")
        #expect(!FileManager.default.fileExists(atPath: q.url.appending(path: "session.xml").path))
    }

    /// C3: one identity on both sides, also after a rename of the package: no copy.
    @Test func theSamePackageCopiesNoFile() throws {
        let excerpt = try q.session.excerpt(of: 0..<48_000, on: ["u2"])
        let id = PackageID(lockFileOf: q.url)
        let before = try names(q)
        let moved = q.folder.url.appending(path: "Moved.dirigible")
        try #require(rename(q.url.path, moved.path) == 0)
        defer { _ = rename(moved.path, q.url.path) }
        var expected = q.session
        let ids = try expected.paste(excerpt, at: 480_000, on: ["u1"])

        let (session, clips, _) = try pasteClipboard(
            Clipboard(excerpt, package: q.url, origin: id), from: moved, into: q.session, in: moved,
            identity: PackageID(lockFileOf: moved), at: 480_000, on: .tracks(["u1"]), freeBytes: { 0 })

        #expect(session == expected && clips == ids)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: moved.appending(path: clipsFolderName).path).sorted()
                == before)
    }

    /// C3e: a source with no `.lock` file has a nil identity and copies; so does a nil target.
    @Test func aNilIdentityCopies() throws {
        let excerpt = try q.session.excerpt(of: 0..<48_000, on: ["u2"])

        let (session, _, _) = try pasteClipboard(
            Clipboard(excerpt, package: q.url, origin: nil), from: q.url, into: q.session, in: q.url,
            identity: nil, at: 480_000, on: .tracks(["u1"]), freeBytes: { .max })

        #expect(try names(q) == ["take1-mic 2.wav", "take1-mic.wav"])
        #expect(session.clip("Z@480000")?.clip.file == "take1-mic 2")
    }

    /// C5b, C5c: a missing package or file refuses before any copy.
    @Test func aMissingSourceFileRefusesAndCopiesNothing() throws {
        let clipboard = try clipboard
        let before = try names(q)
        try FileManager.default.removeItem(at: p.url.appending(path: "\(clipsFolderName)/take2-mic.wav"))

        #expect(throws: PasteError.sourceMissing(file: "take2-mic.wav")) { try paste(clipboard) }
        #expect(try names(q) == before, "the other file is not copied either")

        try FileManager.default.removeItem(at: p.url)
        #expect(throws: PasteError.sourceMissing(file: "Mix.dirigible")) { try paste(clipboard) }
        #expect(try names(q) == before)
    }

    /// C5b2: another package at the path of P.
    @Test func anotherPackageAtTheSourcePathRefuses() throws {
        let clipboard = try clipboard
        let lock = p.url.appending(path: ".lock")
        try FileManager.default.removeItem(at: lock)
        let other = p.url.appending(path: "other")
        FileManager.default.createFile(atPath: other.path, contents: nil)  // holds the old inode number away
        FileManager.default.createFile(atPath: lock.path, contents: nil)

        #expect(throws: PasteError.sourceMissing(file: "Mix.dirigible")) { try paste(clipboard) }
        #expect(try names(q) == ["take1-mic.wav"])
    }

    /// C7a: no check for a clone; the bytes and the margin for a copy, at the exact limit.
    @Test func theSpaceCheckCountsOnlyACopyToAnotherVolume() throws {
        let clipboard = try clipboard
        let bytes = Int64(bytes(p, "take1-mic.wav")!.count + bytes(p, "take2-mic.wav")!.count)
        let needed = bytes + diskMargin

        #expect(throws: PasteError.space(needed: needed, free: needed - 1)) {
            try paste(clipboard, free: needed - 1, canClone: { _, _ in false })
        }
        #expect(try names(q) == ["take1-mic.wav"])
        _ = try paste(clipboard, free: 0, canClone: { _, _ in true })
        #expect(try names(q).count == 3, "a clone needs no free space")
        let r = try MixPackage()
        try r.session.addTrack("u1", name: "u1", layout: .mono)
        try r.session.addTrack("u2", name: "u2", layout: .mono)
        _ = try pasteClipboard(
            clipboard, from: p.url, into: r.session, in: r.url, identity: nil, at: 0, on: .tracks(["u1", "u2"]),
            freeBytes: { needed }, canClone: { _, _ in false })
    }

    /// C7a2: each file fits alone; the sum does not.
    @Test func theSpaceCheckSumsAllFiles() throws {
        let clipboard = try clipboard
        let bytes = Int64(bytes(p, "take1-mic.wav")!.count + bytes(p, "take2-mic.wav")!.count)
        let free = bytes + diskMargin - 1

        #expect(throws: PasteError.space(needed: bytes + diskMargin, free: free)) {
            try paste(clipboard, free: free, canClone: { _, _ in false })
        }
        #expect(try names(q) == ["take1-mic.wav"])
    }

    /// C11: a refused edit moves no byte.
    @Test func aRefusedPasteCopiesNothing() throws {
        #expect(throws: PasteError.session(.trackCount(2))) { try paste(try clipboard, on: .tracks(["u1"])) }
        #expect(try names(q) == ["take1-mic.wav"])
    }

    /// C12: the header of the copy must match the file record.
    @Test func aSourceThatDiffersFromItsRecordRefuses() throws {
        let clipboard = try clipboard
        _ = try p.truncate("take1-mic", toBytes: 100_000)

        #expect(throws: PasteError.sourceChanged(file: "take1-mic.wav")) { try paste(clipboard) }
        #expect(try names(q) == ["take1-mic.wav"], "no .tmp stays")
    }

    /// C18 at the library: no selected track makes one track per lane with its name and layout.
    @Test func newTracksTakeTheSourceNamesAndLayouts() throws {
        let (session, clips, tracks) = try paste(try clipboard, on: .unselected)

        #expect(session.tracks.map(\.name) == ["u1", "u2", "t1", "t2"])
        #expect(session.tracks.suffix(2).map(\.id) == tracks && session.tracks.allSatisfy { $0.layout == .mono })
        #expect(clips.count == 3 && session.clip("C@480000")?.track == tracks.last)
    }

    /// A cancel before the first file copies nothing.
    @Test func aCancelBeforeTheFirstFileCopiesNothing() throws {
        #expect(throws: PasteError.cancelled) { try paste(try clipboard, isCancelled: { true }) }
        #expect(try names(q) == ["take1-mic.wav"])
    }

    /// C3d: a target that the user cannot write refuses with the write error and changes nothing.
    @Test func aTargetThatNothingCanWriteRefuses() throws {
        let clips = q.url.appending(path: clipsFolderName)
        chmod(clips.path, 0o555)
        defer { chmod(clips.path, 0o755) }

        #expect(throws: PasteError.write(file: "take1-mic 2.wav", errno: EACCES)) { try paste(try clipboard) }
        #expect(try names(q) == ["take1-mic.wav"])
    }

    /// C5: a flush fault of a copied file is a write fault of that file, and no new name stays.
    @Test func aFlushFaultOfACopyIsAWriteFault() throws {
        #expect(throws: PasteError.write(file: "take2-mic.wav", errno: EIO)) {
            try pasteClipboard(
                try clipboard, from: p.url, into: q.session, in: q.url, identity: PackageID(lockFileOf: q.url),
                at: 480_000, on: .tracks(["u1", "u2"]), freeBytes: { .max },
                flush: { $0.hasSuffix("/.take2-mic.wav.tmp") ? EIO : nil })
        }
        #expect(try names(q) == ["take1-mic.wav"], "no new name stays")
    }

    /// The `copyfile` callback: no call after the return. The test counts the calls in its own
    /// flag closure, which the callback reads at each call.
    @Test func theCopyCallbackStopsAtTheReturn() throws {
        let source = p.url.appending(path: "\(clipsFolderName)/take1-mic.wav")
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let context = CopyContext(
            isCancelled: {
                calls.withLock { $0 += 1 }
                return false
            }, copied: { _ in })
        #expect(copyFile(source, to: q.url.appending(path: "copy.wav"), clone: false, context: context) == nil)
        let count = calls.withLock { $0 }
        Thread.sleep(forTimeInterval: 0.05)
        #expect(calls.withLock { $0 } == count)
    }

    /// Code gate 1 nit: a link in Clips/ of the source copies as its target, not as a link.
    @Test func aLinkInTheSourceCopiesItsTarget() throws {
        let wav = p.url.appending(path: "\(clipsFolderName)/take2-mic.wav")
        let moved = p.folder.url.appending(path: "outside.wav")
        try FileManager.default.moveItem(at: wav, to: moved)
        try FileManager.default.createSymbolicLink(at: wav, withDestinationURL: moved)

        for (index, clone) in [false, true].enumerated() {
            _ = try paste(try clipboard, canClone: { _, _ in clone })
            let name = index == 0 ? "take2-mic.wav" : "take2-mic 2.wav"
            let copy = q.url.appending(path: "\(clipsFolderName)/\(name)")
            let kind = try FileManager.default.attributesOfItem(atPath: copy.path)[.type] as? FileAttributeType
            #expect(kind == .typeRegular, "\(name) is a file, not a link (clone \(clone))")
            #expect(FileManager.default.contents(atPath: copy.path) == FileManager.default.contents(atPath: moved.path))
        }
    }

    /// Code gate 1 item 2: a record shorter than its WAV (`dirigible file add --length`) pastes; the
    /// read-back needs at least the record length, as `openMedia` does.
    @Test func aRecordShorterThanItsFilePastes() throws {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "take1-mic", path: "take1-mic.wav", layout: .mono, length: 96_000))
        try session.addTrack("t1", name: "t1", layout: .mono)
        try session.place(Clip(id: "A", file: "take1-mic", start: 0, offset: 0, length: 96_000), on: "t1")
        let clipboard = Clipboard(
            try session.excerpt(of: 0..<96_000, on: ["t1"]), package: p.url, origin: PackageID(lockFileOf: p.url))

        let (pasted, clips, _) = try paste(clipboard, on: .tracks(["u1"]))

        #expect(pasted.files["take1-mic 2"]?.length == 96_000 && pasted.clip(clips[0])?.clip.length == 96_000)
    }

    /// Code gate 1 item 2: an ENOENT of `copyfile` is a missing source only when the source is gone.
    @Test func aMissingTargetIsNotAMissingSource() throws {
        let record = try #require(p.session.files["take1-mic"])
        let source = p.url.appending(path: "\(clipsFolderName)/take1-mic.wav")
        let copy = AudioFile(id: "take1-mic 2", path: "take1-mic 2.wav", layout: .mono, length: 192_000)

        #expect(
            copyFault(ENOENT, from: source, record: record, copy: copy)
                == .write(file: "take1-mic 2.wav", errno: ENOENT))
        #expect(copyFault(EIO, from: source, record: record, copy: copy) == .write(file: "take1-mic 2.wav", errno: EIO))
        try FileManager.default.removeItem(at: source)
        #expect(copyFault(ENOENT, from: source, record: record, copy: copy) == .sourceMissing(file: "take1-mic.wav"))
    }
}
