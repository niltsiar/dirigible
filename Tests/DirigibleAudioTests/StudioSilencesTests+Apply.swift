import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// Apply of a silence scan through `Studio.applySilences` (decision 0066, criteria C17 to C19), on
/// the three silences of `threeSilences` with a keep of 500 ms (24 000 frames).
extension StudioSilencesTests {
    /// A plan of the three rows: shorten the first (cut 60 000 ..< 108 000), mute the second, and
    /// mark the third.
    static func plan(_ scan: SilenceScan, shorten: Bool = true) throws -> SilencePlan {
        let rows = scan.silences
        try #require(rows == threeRows, "the scan rows: \(rows)")
        let edits = [
            SilenceEdit(range: rows[0], action: .shorten), SilenceEdit(range: rows[1], action: .mute),
            SilenceEdit(range: rows[2], action: .mark(name: "Silence 1")),
        ]
        return try SilencePlan(shorten ? edits : Array(edits.dropFirst()), keep: 24_000)
    }

    /// C17: one Apply is one undo entry: Undo gives the session before Apply, Redo the applied one.
    @Test func applyIsOneUndoEntry() async throws {
        let package = try Self.package([Self.threeSilences()])
        defer { withExtendedLifetime(package) {} }
        let studio = try await Studio.open(package.url)
        let scan = try await Self.scan(studio)
        let before = studio.session

        let result = try studio.applySilences(try Self.plan(scan), scan: scan)

        #expect(result.cuts == [60_000..<108_000] && result.removed == 48_000, "\(result)")
        let applied = studio.session
        #expect(applied.end == 288_000 && applied.markers.count == 1, "end \(applied.end)")
        let envelope = applied.track("t1")?.clips.first?.envelope
        #expect(envelope != before.track("t1")?.clips.first?.envelope, "the mute changed no gain")
        try studio.undo()
        let undone = studio.session == before
        #expect(undone && !studio.canUndo, "one Undo does not give back the session before Apply")
        try studio.redo()
        let redone = studio.session == applied
        #expect(redone, "Redo does not give back the applied session")
    }

    /// A studio on a package with a pending take and the three silences, so it cannot ripple.
    static func pendingTakeStudio() async throws -> (MixPackage, Studio) {
        let package = try Self.package([Self.threeSilences()])
        try package.session.setRecording(
            Recording(take: 1, playheadFrame: 0, takeStartHostTimeNanos: takeStart, armedTracks: ["t1"]))
        try package.session.write(to: package.url)
        try FileManager.default.createDirectory(
            at: package.url.appending(path: "Capture"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: package.url.appending(path: "recovery-attempt").path, contents: nil)
        let studio = try await Studio.open(package.url)
        studio.environment = .test(TestHAL([]))
        try #require(studio.pendingTake != nil && !studio.canRipple, "no pending take")
        return (package, studio)
    }

    /// C18: under a pending take, a plan that removes frames refuses as a ripple and changes nothing;
    /// a plan of a mute and a mark applies.
    @Test func aSplitTakeRefusesAShortenAndAllowsMuteAndMark() async throws {
        let (package, studio) = try await Self.pendingTakeStudio()
        defer { withExtendedLifetime(package) {} }
        let scan = try await Self.scan(studio)
        let before = studio.session

        #expect(throws: StudioError.rippleBlocked) { try studio.applySilences(try Self.plan(scan), scan: scan) }
        let unchanged = studio.session == before
        #expect(unchanged && !studio.canUndo, "a refused Apply changed the session")

        let result = try studio.applySilences(try Self.plan(scan, shorten: false), scan: scan)
        #expect(result.cuts.isEmpty && result.markers.count == 1, "\(result)")
        let marker = try #require(studio.session.markers[result.markers[0]])
        #expect(marker.position == 264_000 && studio.session.end == 336_000, "\(marker.position)")
        let envelope = studio.session.track("t1")?.clips.first?.envelope
        #expect(envelope != before.track("t1")?.clips.first?.envelope, "the mute changed no gain")
    }

    /// A plan counts as a ripple only when a cut removes frames. The first row has 72 000 frames:
    /// a keep of 72 000 cuts nothing, so the Shorten and a Mute apply under a pending take; a keep
    /// of 71 999 cuts one frame, so the plan is refused. Fail value: `.rippleBlocked` for the first plan.
    @Test func aShortenThatCutsNothingDoesNotBlockUnderAPendingTake() async throws {
        let (package, studio) = try await Self.pendingTakeStudio()
        defer { withExtendedLifetime(package) {} }
        let scan = try await Self.scan(studio)
        let rows = scan.silences
        let edits = [SilenceEdit(range: rows[0], action: .shorten), SilenceEdit(range: rows[1], action: .mute)]
        let before = studio.session

        #expect(throws: StudioError.rippleBlocked) {
            try studio.applySilences(try SilencePlan(edits, keep: 71_999), scan: scan)
        }
        let unchanged = studio.session == before
        #expect(unchanged, "a refused Apply changed the session")

        let result = try studio.applySilences(try SilencePlan(edits, keep: 72_000), scan: scan)
        #expect(result.cuts.isEmpty && result.skipped == [1], "\(result)")
        let envelope = studio.session.track("t1")?.clips.first?.envelope
        #expect(envelope != before.track("t1")?.clips.first?.envelope, "the mute changed no gain")
    }

    /// C19: a marker add, a mute, and a rename after the scan do not stop Apply, and the new
    /// marker follows Rule M. A clip gain change after the scan stops Apply with no change.
    @Test func anEditAfterTheScanStopsApplyAndMuteDoesNot() async throws {
        let package = try Self.package([Self.threeSilences()])
        defer { withExtendedLifetime(package) {} }
        let studio = try await Studio.open(package.url)
        let scan = try await Self.scan(studio)
        let added = MarkerID()
        try studio.edit(ripple: false) { session throws(SessionError) in
            try session.setMarker(Marker(id: added, name: "Later", position: 300_000, kind: .marker))
            try session.setMuted(true, tracks: ["t1"])
            try session.renameTrack("t1", to: "Host")
        }

        try studio.applySilences(try Self.plan(scan), scan: scan)
        #expect(
            studio.session.markers[added]?.position == 252_000, "\(String(describing: studio.session.markers[added]))")

        let again = try await Self.scan(studio)
        let first = try #require(again.silences.first, "no row after the first Apply")
        try studio.edit(ripple: false) { session throws(SessionError) in try session.setGain(Gain(dB: -1)!, clip: "c1")
        }
        let before = studio.session
        #expect(throws: StudioError.silencesStale) {
            try studio.applySilences(
                try SilencePlan([SilenceEdit(range: first, action: .shorten)], keep: 0), scan: again)
        }
        let unchanged = studio.session == before
        #expect(unchanged, "a stale Apply changed the session")
    }

    /// C19: a scan is current for a session with the frames it read, also after a marker add, a mute,
    /// and a rename; a clip gain change makes it out of date, and an undo makes it current again.
    @Test func aScanIsCurrentOnlyForTheFramesItRead() async throws {
        let package = try Self.package([Self.threeSilences()])
        defer { withExtendedLifetime(package) {} }
        let studio = try await Studio.open(package.url)
        let scan = try await Self.scan(studio)
        #expect(scan.isCurrent(in: studio.session), "the scanned session")
        try studio.edit(ripple: false) { session throws(SessionError) in
            try session.setMarker(Marker(id: MarkerID(), name: "Later", position: 300_000, kind: .marker))
            try session.setMuted(true, tracks: ["t1"])
            try session.renameTrack("t1", to: "Host")
        }
        #expect(scan.isCurrent(in: studio.session), "a marker, a mute, and a rename")
        try studio.edit(ripple: false) { session throws(SessionError) in try session.setGain(Gain(dB: -1)!, clip: "c1")
        }
        #expect(!scan.isCurrent(in: studio.session), "a clip gain")
        try studio.undo()
        #expect(scan.isCurrent(in: studio.session), "the undo")
    }
}
