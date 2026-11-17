import AppKit
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// The match mark of a header row (decision 0074, criteria C21 and C22). The test process builds no
/// SwiftUI accessibility tree for a hosted view, so the label and the value are checked through
/// `MatchMarkState` (`MatchVoiceWindowTests.statesAndValues`) and on screen.
extension HeaderRowTests {
    func matchOf(_ percent: Int = 75) throws -> VoiceMatch {
        try VoiceMatch(
            amount: try #require(.init(percent)), reference: "take4-1-1 interview studio mics",
            curve: Array(repeating: 2.0, count: 25), targetPowers: Array(repeating: 1, count: 25))
    }

    /// C21: a matched track adds the mark to its row. The rows of the other tracks stay as they
    /// were, and a removed match gives the old row back.
    @Test func aMatchedTrackShowsTheMark() async throws {
        let (model, studio) = try await model(tracks: 3)
        let plain = try await rowPixels(model, studio)

        let match = try matchOf()
        try studio.edit(ripple: false) { session throws(SessionError) in try session.setMatch(["t2": match]) }
        let marked = try await rowPixels(model, studio)
        model.removeMatch(tracks: ["t2"])
        let removed = try await rowPixels(model, studio)

        func changed(_ a: [[UInt32]], _ b: [[UInt32]], _ row: Int) -> Int {
            zip(a[row], b[row]).filter { $0 != $1 }.count
        }
        #expect(changed(plain, marked, 1) > 20, "the mark: \(changed(plain, marked, 1)) pixels")
        #expect(changed(plain, marked, 0) == 0 && changed(plain, marked, 2) == 0, "the other rows stay")
        #expect(changed(plain, removed, 1) == 0, "no match: no mark")
        await model.close()
    }

    /// C22: a row with a role, a match, and a full live state, and a row with a role, the follow
    /// glyph, and a match, stay inside the row at each width gate, on one line and on two lines, and
    /// at the minimum header width. The mark width comes out of the name minimum. A row with the
    /// role, the follow glyph, a match, and a live state needs 12 pt more than 180 pt on one line:
    /// the follow glyph and the live state already fill that row with the name at its minimum. Control: the mark width left out of
    /// `HeaderGlyphs.room` puts a view outside the row at 180 pt.
    @Test func aMatchedRowStaysInsideTheRowAtEachWidthGate() async throws {
        let (model, studio) = try await model(tracks: 3)
        studio.liveTracks["t1"] = LiveTrack(state: .deviceLost, droppedFrames: 0, peak: 0)
        studio.liveTracks["t2"] = LiveTrack(
            state: .recording, droppedFrames: 3, peak: 0.1, shortTerm: LUFS(value: -17.4))
        model.setRole(.dialogue, tracks: ["t1", "t2", "t3"])
        model.setFollowTrack(true, tracks: ["t3"])
        let match = try matchOf()
        try studio.edit(ripple: false) { session throws(SessionError) in
            try session.setMatch(["t1": match, "t2": match, "t3": match])
        }
        let forms = [
            (
                50.0,
                [180.0, TrackHeaders.muteSoloWidth, TrackHeaders.monitorWidth]
                    + [TrackHeaders.compactLoudnessWidth]
            ),
            (
                100.0,
                [
                    180.0, TrackHeaders.muteSoloTwoLineWidth, TrackHeaders.monitorTwoLineWidth,
                    TrackHeaders.faderTwoLineWidth,
                ]
            ),
        ]
        for (lane, widths) in forms {
            for width in widths {
                let (window, host) = rows(model, studio, laneHeight: lane, width: width)
                let out = outside(host, width: width)
                #expect(out.isEmpty, "inside the row: \(lane) pt lanes at \(width) pt: \(out)")
                window.close()
            }
        }
        await model.close()
    }
}
