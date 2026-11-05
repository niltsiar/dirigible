import Foundation
import Testing

@testable import DirigibleCore

/// Decision 0071 (C9): a stem WAV whose CAF is gone is the only copy of its take
/// audio. The caller gives these WAVs as `soleCopies`; the scan never lists one as a stray WAV.
/// An unused pool entry of one is a pool item, as for each pool file (code gate item 3).
extension UnusedFilesTests {
    /// Fail value: `take1-1-1.wav` with no CAF, which the scan of decision 0047 lists as a stray.
    /// Near value: `take1-2-1.wav`, a stem WAV that still has its CAF, so it is not a sole copy.
    @Test func aSoleCopyWAVIsNotAStrayWAV() throws {
        let session = try Self.session([])
        try plant("take1-1-1.wav")
        try plant("take1-2-1.wav")

        let scan = try scan(session, soleCopies: ["take1-1-1.wav"])

        #expect(scan.items.map(\.kind) == [.stray] && Self.paths(scan) == ["take1-2-1.wav"], "\(scan.items)")
        #expect(scan.kept == UnusedFiles.Kept(count: 0, bytes: 0))
    }

    /// An unused pool entry of a sole-copy WAV that no holder names is a pool item: the prune
    /// drops the entry and moves the file, as for the unused entry of `take1-2-1.wav`, whose CAF
    /// is still there.
    @Test func aPruneMovesTheWAVOfAnUnusedSoleCopyEntry() throws {
        var session = try Self.session([("t1", "take1-1-1.wav"), ("t2", "take1-2-1.wav")])
        try plant("take1-1-1.wav", bytes: 6)
        try plant("take1-2-1.wav")

        let scan = try scan(session, soleCopies: ["take1-1-1.wav"])
        var trashed: [String] = []
        let report = try scan.prune(&session, save: save) { url in
            trashed.append(url.lastPathComponent)
            return Self.fakeTrashURL(url)
        }

        #expect(Set(scan.items.map(\.kind)) == [.pool("t1"), .pool("t2")], "\(scan.items)")
        #expect(Set(trashed) == ["take1-1-1.wav", "take1-2-1.wav"] && report.failed.isEmpty, "\(report)")
        #expect(session.files.isEmpty, "both entries are gone")
        #expect(try Session(contentsOf: package).files.isEmpty, "the save has no entry")
    }

    /// A backup that uses the sole-copy WAV keeps the entry and the file, as for each pool file.
    @Test func aHolderKeepsASoleCopyEntry() throws {
        var session = try Self.session([("t1", "take1-1-1.wav")])
        try plant("take1-1-1.wav", bytes: 6)
        try backup(try Self.session([("t1", "take1-1-1.wav")], used: ["t1"]))

        let scan = try scan(session, soleCopies: ["take1-1-1.wav"])
        let report = try scan.prune(&session, save: save, trash: Self.fakeTrashURL)

        #expect(scan.items.isEmpty && scan.kept == UnusedFiles.Kept(count: 1, bytes: 6), "\(scan.items)")
        #expect(report.moved.isEmpty && session.files["t1"] != nil)
    }
}
