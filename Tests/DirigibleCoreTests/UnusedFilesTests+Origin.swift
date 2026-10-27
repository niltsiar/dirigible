import Foundation
import Testing

@testable import DirigibleCore

/// Decision 0057: the origin chain of a held file is held too (run render-link, criteria C7 and
/// C13). Each chain is a rendered file and its source, both mono with 48 000 frames.
extension UnusedFilesTests {
    /// The session of `session(_:used:)` with the files `source` and `rendered`, a render of
    /// `source`, and a clip on `rendered` when `placed`.
    static func chain(
        _ rendered: FileID, of source: FileID, placed: Bool, others: [(FileID, String)] = []
    ) throws -> Session {
        var session = try Self.session([(source, "\(source.rawValue).wav")] + others)
        let origin = RenderOrigin(source: source, offset: 0, treatment: Treatment(.noise(.standard)), addedGain: .zero)
        try session.addFile(
            AudioFile(id: rendered, path: "\(rendered.rawValue).wav", layout: .mono, length: 48_000, origin: origin))
        if placed { try session.place(Clip(id: "c", file: rendered, start: 0, offset: 0, length: 1), on: "a") }
        return session
    }

    /// C7. A clip on the rendered file keeps its source and the pool entry of the source. The
    /// unrelated file "u" is the one item, and the prune moves only it.
    @Test func originSourceIsKept() throws {
        var session = try Self.chain("r", of: "s", placed: true, others: [("u", "u.wav")])
        for name in ["r.wav", "s.wav", "u.wav"] { try plant(name) }

        let scan = try scan(session)
        let report = try scan.prune(&session, save: save, trash: Self.fakeTrashURL)

        #expect(Self.paths(scan) == ["u.wav"])
        #expect(report.moved.map(\.item.path) == ["u.wav"] && report.failed.isEmpty)
        #expect(session.files["u"] == nil && session.files["s"] != nil && session.files["r"]?.origin?.source == "s")
    }

    /// C7. A clip of an undo entry or of a backup on the rendered file keeps its source too. The
    /// session has no clip on either file, so only the chain of the holder keeps "s".
    @Test func heldRenderKeepsItsSource() throws {
        let holder = try Self.chain("r", of: "s", placed: true)
        let session = try Self.chain("r", of: "s", placed: false)
        for name in ["r.wav", "s.wav"] { try plant(name) }
        #expect(Self.paths(try scan(session)) == ["r.wav", "s.wav"], "control: no holder")

        let byEntry = try scan(session, keptBy: [holder])
        try backup(holder)
        let byBackup = try scan(session)

        for kept in [byEntry, byBackup] {
            #expect(kept.items.isEmpty, "items: \(Self.paths(kept))")
            #expect(kept.kept.count == 2)
        }
    }

    /// C7 and C13. A rendered file that nothing holds goes, and so does its source. The prune
    /// removes both pool entries in any order of the set: 20 chains with new IDs.
    @Test func unusedChainGoesInAnyOrder() throws {
        for run in 0..<20 {
            let (rendered, source) = (FileID("r\(run)"), FileID("s\(run)"))
            var session = try Self.chain(rendered, of: source, placed: false)
            let planted = try [rendered, source].map { try plant("\($0.rawValue).wav") }
            let scan = try scan(session)

            let report = try scan.prune(&session, save: save, trash: Self.fakeTrashURL)

            #expect(Set(Self.paths(scan)) == ["\(rendered.rawValue).wav", "\(source.rawValue).wav"], "run \(run)")
            #expect(report.moved.count == 2 && session.files.isEmpty, "run \(run)")
            // The fake trash moves nothing: the next run must not see these files as strays.
            for url in planted { try FileManager.default.removeItem(at: url) }
        }
    }
}
