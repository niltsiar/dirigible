import AVFoundation
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// C39: a favorite stores only the source frames that its clips play, and a paste of it renders the
/// same samples as a paste of the source range.
extension FavoritesTests {
    /// A 10 s noise file "long" at `rate` on track t1: clip A plays 2 s to 3 s of the file at 0, and
    /// clip B plays 7 s to 7.5 s at 1 s, with a 0.1 s crossfade at the join, a fade-out on B, and two
    /// envelope points on A. The copy is the range from 0.1 s to 1.5 s, so A is cut at its start.
    static func extentSource(rate: Int) throws -> (MixPackage, Clipboard) {
        let source = try MixPackage(sampleRate: rate, name: "Show")
        var state: UInt32 = 1
        let noise = (0..<(10 * rate)).map { _ in
            state = state &* 1_664_525 &+ 1_013_904_223
            return Float(Int32(bitPattern: state)) / Float(Int32.max) * 0.25
        }
        try source.addFile("long", channels: [noise])
        // Frames of `tenths` tenths of a second.
        func at(_ tenths: Int) -> Frames { Frames(rate * tenths / 10) }
        try source.addTrack("t1", clip: "A", file: "long", start: .zero, offset: at(20), length: at(10))
        try source.session.place(Clip(id: "B", file: "long", start: at(10), offset: at(70), length: at(5)), on: "t1")
        try source.session.setCrossfades(["A": at(1)])
        try source.session.setFades(["B": Fades(fadeIn: .zero, fadeOut: at(1))!])
        try source.session.setEnvelope([at(5): Gain(dB: -6)!, at(8): .zero], clip: "A")
        try source.session.write(to: source.url)
        FileManager.default.createFile(atPath: source.url.appending(path: ".lock").path, contents: nil)
        let clipboard = Clipboard(
            try source.session.excerpt(of: at(1)..<at(15), on: ["t1"]), package: source.url,
            origin: PackageID(lockFileOf: source.url))
        return (source, clipboard)
    }

    /// A new 48000 Hz package with one mono track and `clipboard` pasted at 0 on it.
    static func pasted(_ clipboard: Clipboard, from source: URL) throws -> MixPackage {
        let target = try MixPackage(name: "B")
        try target.session.addTrack("u1", name: "u1", layout: .mono)
        FileManager.default.createFile(atPath: target.url.appending(path: ".lock").path, contents: nil)
        target.session =
            try pasteClipboard(
                clipboard, from: source, into: target.session, in: target.url,
                identity: PackageID(lockFileOf: target.url), mode: .over(at: .zero), on: .tracks(["u1"]),
                freeBytes: { .max }
            ).session
        return target
    }

    @Test(arguments: [48_000, 44_100])
    func addStoresOnlyTheClipExtents(rate: Int) throws {
        let (source, clipboard) = try Self.extentSource(rate: rate)
        let store = source.folder.url.appending(path: "Favorites.dirigible")

        let id = try Favorites.add(
            clipboard, from: source.url, named: "Sting", bin: nil, store: store,
            log: { favoritesJournal(source.folder) })

        let lengths = try clipNames(store).map {
            try AVAudioFile(forReading: store.appending(path: "\(clipsFolderName)/\($0)")).length
        }
        if rate == 48_000 {
            #expect(lengths.sorted() == [26_400, 45_600], "one WAV for each run of the clip extents: \(lengths)")
        } else {
            // The runs 90552..<136553 and 304437..<332798: 2048 frames at each edge, the start on a
            // multiple of 147, converted to 48000 Hz.
            let runs = [28_361.0, 46_001.0].map { $0 * 48_000 / 44_100 }
            #expect(
                lengths.count == 2 && zip(lengths.sorted(), runs).allSatisfy { abs(Double($0) - $1) < 1 },
                "the converted runs only: \(lengths)")
        }
        let read = try Session(contentsOf: store)
        let length = try #require(read.bins.flatMap(\.items).first { $0.id == id }?.length)
        let favorite = Clipboard(try read.excerpt(of: id), package: store, origin: PackageID(lockFileOf: store))
        let fromFavorite = try Self.pasted(favorite, from: store).mix(.zero..<length)
        let fromSource = try Self.pasted(clipboard, from: source.url).mix(.zero..<length)
        let difference = zip(fromFavorite[0], fromSource[0]).map { abs($0 - $1) }.max() ?? .infinity
        #expect(fromFavorite[0].count == Int(length.count) && fromFavorite[0].contains { $0 != 0 })
        #expect(fromFavorite == fromSource, "the same samples, largest difference \(difference)")
    }
}
