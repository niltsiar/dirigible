import Foundation
import Testing

@testable import DirigibleAudio
@testable import DirigibleCore

/// The take time of each capture file (decision 0061): file frame 0 of a finalized file is at its
/// aligned start minus the playhead at record start, read from the take anchor.
struct TakeOriginTests {
    /// The origins of the files of `session`, with the anchors on disk in `package`.
    func origins(_ session: Session, _ package: URL) throws -> [FileID: TakeMap.Origin] {
        let anchors = try TakeAnchors.read(package).compactMapValues { try? $0.get() }
        return TakeMap(session, recordings: takeRecordings(session, anchors: anchors)).origins
    }

    /// The real finalize at playhead 48000 with three devices of one take, each with a latency of
    /// 156 frames: one at 48 kHz, one at 44.1 kHz that finalize resamples, and one whose first
    /// frame is 1.5 s before the take start, so its aligned start is negative.
    @Test func eachFinalizedFileHasItsPlacementAsOrigin() throws {
        let package = try TakePackage(tracks: [("t1", .mono), ("t2", .mono), ("t3", .mono)], playhead: 48_000)
        try package.segment(
            arm: 1, header: TakePackage.header(latency: 156, firstHost: takeStart + 10_000_000),
            samples: sine(seconds: 1, rate: 48_000))
        try package.segment(
            arm: 2, header: TakePackage.header(rate: 44_100, latency: 156, firstHost: takeStart + 23_000_000),
            samples: sine(seconds: 1, rate: 44_100))
        try package.segment(
            arm: 3, header: TakePackage.header(latency: 156, firstHost: takeStart - 1_500_000_000),
            samples: sine(seconds: 2, rate: 48_000))

        // The map reads the captures of `session.xml`, so the origins come from the saved session.
        try finalizeTake(of: package.read(), in: package.url).write(to: package.url)
        let session = try package.read()

        #expect(session.captures["take1-2-1"]?.resampledFromRate == 44_100)
        // The clip starts at the playhead 48000: 48000 + 24156 frames go to the offset.
        #expect(session.track("t3")?.clips.first?.offset == 72_156)
        let found = try origins(session, package.url)
        // 480 - 156; 1104 - round(156 x 48000 / 44100) = 170; -72000 - 156.
        #expect(
            found == [
                "take1-1-1": TakeMap.Origin(take: 1, frame: 324), "take1-2-1": TakeMap.Origin(take: 1, frame: 934),
                "take1-3-1": TakeMap.Origin(take: 1, frame: -72_156),
            ])
        for clip in session.tracks.flatMap(\.clips) {
            #expect(found[clip.file]?.frame == clip.start.count - clip.offset.count - 48_000, "\(clip.id)")
        }
    }

    enum NoTakeTime: String, CaseIterable, CustomTestStringConvertible {
        case importedFile, pasteAcrossPackages, derivedFile, noAnchorFile, newerAnchor, unparsedAnchor
        var testDescription: String { rawValue }
    }

    /// A file has take time only when its capture ID equals its file ID and the anchor of its take
    /// reads. The finalized file of take 1 has origin 432: 10 ms (480) minus 48 frames of latency.
    @Test(arguments: NoTakeTime.allCases)
    func onlyAFinalizedFileWithAnAnchorHasTakeTime(_ kind: NoTakeTime) throws {
        let package = try TakePackage()
        try package.segment(samples: sine(seconds: 1, rate: 48_000))
        var session = try finalizeTake(of: package.read(), in: package.url)
        let finalized: [FileID: TakeMap.Origin] = ["take1-1-1": TakeMap.Origin(take: 1, frame: 432)]
        #expect(try origins(session, package.url) == finalized)
        let anchor = package.capture.appending(path: "take1.anchor")

        var added: FileID?
        switch kind {
        case .importedFile:
            added = "music"
            try session.addFile(AudioFile(id: "music", path: "music.wav", layout: .mono, length: 48_000))
        case .pasteAcrossPackages:
            // The record that `PasteClipboard` makes for a file of another package: a stem, no capture.
            added = "take1-2-1"
            try session.addFile(AudioFile(id: "take1-2-1", path: "take1-2-1.wav", layout: .mono, length: 48_000))
        case .derivedFile:
            let run = try #require(session.clipRuns(of: ["take1-1-1"]).first)
            added = try session.addDerivedFile(from: run, stem: "take1-1-1-part", layout: .mono, origin: nil)
        case .noAnchorFile:
            try FileManager.default.removeItem(at: anchor)
        case .newerAnchor:
            try setMagicDigit(anchor, "3")
        case .unparsedAnchor:
            try Data("not an anchor".utf8).write(to: anchor)
        }

        let found = try origins(session, package.url)
        if let added {
            #expect(session.files[added] != nil)
            #expect(found == finalized)
        } else {
            #expect(found == [:])
        }
    }

    /// An errno other than ENOENT is not "no anchor": it is the entry of its take.
    @Test func anAnchorReadFaultIsTheEntryOfItsTake() throws {
        let package = try TakePackage()
        try package.segment(samples: sine(seconds: 1, rate: 48_000))
        _ = try finalizeTake(of: package.read(), in: package.url)
        let anchor = package.capture.appending(path: "take1.anchor")
        chmod(anchor.path, 0o000)
        defer { chmod(anchor.path, 0o644) }

        let anchors = try TakeAnchors.read(package.url)
        #expect(anchors.count == 1)
        #expect(throws: FinalizeError.readFailed(file: "Capture/take1.anchor", errno: EACCES)) {
            try anchors[1]?.get()
        }
    }
}
