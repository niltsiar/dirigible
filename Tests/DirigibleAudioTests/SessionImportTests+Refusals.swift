import AVFoundation
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The refusals of the session import (C7): each throws its error and changes nothing.
extension SessionImportTests {
    /// A source "Guest" with one track and one clip of `Clips/a.wav`.
    func plainSource(rate: Int = 48_000) throws -> MixPackage {
        let source = try Self.package("Guest", rate: rate)
        try source.addFile("a", channels: [sine(seconds: 1, rate: Double(rate))])
        try source.addTrack("t1", clip: "A", file: "a", start: 0, offset: 0, length: Frames(rate))
        try source.session.write(to: source.url)
        return source
    }

    /// The target `session.xml` bytes and the `Clips/` listing.
    func targetState() throws -> [String] {
        let xml = FileManager.default.contents(atPath: target.url.appending(path: "session.xml").path)
        return try names(target) + [xml?.base64EncodedString() ?? "none"]
    }

    /// Expects `error` from `call` and the target state of before.
    func expectRefusal(
        _ error: SessionImportError, sourceLocation: SourceLocation = #_sourceLocation,
        _ call: () throws(SessionImportError) -> SessionImported
    ) throws {
        let before = try targetState()
        #expect(throws: error, sourceLocation: sourceLocation) { try call() }
        #expect(try targetState() == before, sourceLocation: sourceLocation)
    }

    @Test func eachRefusalChangesNothing() throws {
        try target.session.write(to: target.url)
        let source = try plainSource()

        try expectRefusal(.sameSession) { () throws(SessionImportError) in try run(target.url) }
        let unlocked = try Self.package("Unlocked")
        try unlocked.session.write(to: unlocked.url)
        try FileManager.default.removeItem(at: unlocked.url.appending(path: ".lock"))
        try expectRefusal(.sameSession) { () throws(SessionImportError) in try run(unlocked.url, into: unlocked) }

        let pending = try plainSource()
        try pending.session.setRecording(
            Recording(take: 1, playheadFrame: 0, takeStartHostTimeNanos: 0, armedTracks: []))
        try pending.session.write(to: pending.url)
        try expectRefusal(.takeNotFinalized) { () throws(SessionImportError) in try run(pending.url) }

        let empty = try Self.package("Empty")
        try empty.session.addTrack("t1", name: "t1", layout: .mono)
        try empty.session.write(to: empty.url)
        try expectRefusal(.nothingToImport) { () throws(SessionImportError) in try run(empty.url, markers: true) }

        let xml = source.url.appending(path: "session.xml")
        let text = try String(contentsOf: xml, encoding: .utf8)
        try text.replacing(#/ version="\d+"/#, with: #" version="999""#, maxReplacements: 1).write(
            to: xml, atomically: true, encoding: .utf8)
        try expectRefusal(.source(.unsupportedVersion(999))) { () throws(SessionImportError) in try run(source.url) }

        let missing = try plainSource()
        try FileManager.default.removeItem(at: missing.url.appending(path: "Clips/a.wav"))
        try expectRefusal(.paste(.sourceMissing(file: "a.wav"))) { () throws(SessionImportError) in
            try run(missing.url)
        }

        // A clone needs no space, so the source rate differs: a conversion counts its bytes.
        let spacious = try plainSource(rate: 44_100)
        var needed: Int64 = 0
        do { _ = try run(spacious.url, free: 0) } catch {
            if case .paste(.space(let need, _)) = error { needed = need }
        }
        #expect(needed > 1_000_000_000, "the need has the 1 GB margin")
        try expectRefusal(.paste(.space(needed: needed, free: needed - 1))) { () throws(SessionImportError) in
            try run(spacious.url, free: needed - 1)
        }
        #expect(try run(spacious.url, free: needed).tracks.count == 1)
    }

    /// C7c2: the offset bound comes before any read: a source that does not exist still gives it.
    @Test func anOffsetOutOfRangeRefusesBeforeAnyRead() throws {
        let nowhere = target.folder.url.appending(path: "Nowhere.dirigible")
        for at in [-(1 << 40) - 1, (1 << 40) + 1] {
            try expectRefusal(.offsetOutOfRange(at)) { () throws(SessionImportError) in try run(nowhere, at: at) }
        }
        let source = try plainSource()
        try expectRefusal(.nothingToImport) { () throws(SessionImportError) in try run(source.url, at: -(1 << 40)) }
        try expectRefusal(.paste(.session(.frameOutOfRange))) { () throws(SessionImportError) in
            try run(source.url, at: 1 << 40)
        }
    }

    /// C7c3: a source rate outside 8000...384000 Hz.
    @Test func aSourceRateOutsideTheRangeIsRefused() throws {
        for rate in [7_999, 1 << 31] {
            let source = try Self.package("Rate", rate: rate)
            try source.session.addFile(AudioFile(id: "a", path: "a.wav", layout: .mono, length: 100))
            try source.session.addTrack("t1", name: "t1", layout: .mono)
            try source.session.place(Clip(id: "A", file: "a", start: 0, offset: 0, length: 100), on: "t1")
            try source.session.write(to: source.url)
            try expectRefusal(.sampleRateOutOfRange(rate)) { () throws(SessionImportError) in try run(source.url) }
        }
        for rate in [8_000, 384_000] {
            #expect(try run(try plainSource(rate: rate).url).tracks.count == 1, "\(rate) Hz imports")
        }
    }

    /// C7c4: a target rate outside 8000...384000 Hz, refused before the read.
    @Test func aTargetRateOutsideTheRangeIsRefused() throws {
        let source = try plainSource()
        for rate in [7_999, 384_001] {
            let target = try Self.package("Target", rate: rate)
            let before = try names(target)
            #expect(throws: SessionImportError.targetSampleRateOutOfRange(rate)) { try run(source.url, into: target) }
            #expect(try names(target) == before)
        }
        for rate in [8_000, 384_000] {
            let target = try Self.package("Target", rate: rate)
            let result = try run(source.url, into: target)
            let path = try #require(result.session.files.values.first?.path)
            #expect(
                try AVAudioFile(forReading: target.url.appending(path: "Clips/\(path)")).fileFormat.sampleRate
                    == Double(rate))
        }
    }

    /// C7g: a link at any component of a named path, or a named folder, is refused before any copy.
    @Test func aLinkedSourceFileIsRefused() throws {
        let outside = target.folder.url.appending(path: "outside.wav")
        let outsideFolder = target.folder.url.appending(path: "outsideFolder")
        try FileManager.default.createDirectory(at: outsideFolder, withIntermediateDirectories: true)

        let linked = try plainSource()
        let a = linked.url.appending(path: "Clips/a.wav")
        try FileManager.default.moveItem(at: a, to: outside)
        try FileManager.default.createSymbolicLink(at: a, withDestinationURL: outside)
        try expectRefusal(.unsafeFile("a.wav")) { () throws(SessionImportError) in try run(linked.url) }

        let inside = try plainSource()
        let b = inside.url.appending(path: "Clips/b.wav")
        try FileManager.default.moveItem(at: inside.url.appending(path: "Clips/a.wav"), to: b)
        try FileManager.default.createSymbolicLink(
            atPath: inside.url.appending(path: "Clips/a.wav").path, withDestinationPath: "b.wav")
        try expectRefusal(.unsafeFile("a.wav")) { () throws(SessionImportError) in try run(inside.url) }

        let sub = try Self.package("Guest")
        try FileManager.default.createDirectory(
            at: sub.url.appending(path: "Clips/sub"), withIntermediateDirectories: true)
        try sub.addFile("a", channels: [sine(seconds: 1, rate: 48_000)], path: "sub/a.wav")
        try sub.addTrack("t1", clip: "A", file: "a", start: 0, offset: 0, length: 48_000)
        try sub.session.write(to: sub.url)
        #expect(try run(sub.url).tracks.count == 1, "a regular file in a real folder imports")
        let real = sub.url.appending(path: "Clips/sub")
        try FileManager.default.moveItem(at: real, to: outsideFolder.appending(path: "sub"))
        try FileManager.default.createSymbolicLink(at: real, withDestinationURL: outsideFolder.appending(path: "sub"))
        try expectRefusal(.unsafeFile("sub/a.wav")) { () throws(SessionImportError) in try run(sub.url) }

        let folder = try Self.package("Guest")
        try FileManager.default.createDirectory(
            at: folder.url.appending(path: "Clips/sub"), withIntermediateDirectories: true)
        try folder.session.addFile(AudioFile(id: "s", path: "sub", layout: .mono, length: 100))
        try folder.session.addTrack("t1", name: "t1", layout: .mono)
        try folder.session.place(Clip(id: "S", file: "s", start: 0, offset: 0, length: 100), on: "t1")
        try folder.session.write(to: folder.url)
        try expectRefusal(.unsafeFile("sub")) { () throws(SessionImportError) in try run(folder.url) }
    }

    /// C7j: the download check comes before the open of the link check.
    @Test func aFileThatIsNotDownloadedIsRefusedBeforeAnyOpen() throws {
        let linked = try plainSource()
        let a = linked.url.appending(path: "Clips/a.wav")
        let outside = target.folder.url.appending(path: "outside.wav")
        try FileManager.default.moveItem(at: a, to: outside)
        try FileManager.default.createSymbolicLink(at: a, withDestinationURL: outside)

        try expectRefusal(.paste(.notDownloaded(file: "a.wav"))) { () throws(SessionImportError) in
            try run(linked.url, isDownloaded: { _ in false })
        }
        try expectRefusal(.unsafeFile("a.wav")) { () throws(SessionImportError) in
            try run(linked.url, isDownloaded: { _ in true })
        }
    }
}
