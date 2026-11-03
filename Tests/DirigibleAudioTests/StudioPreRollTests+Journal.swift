import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The journal lines of a pre-roll take (decision 0070, criteria P23 and P24): the take start
/// line with the parts of the output term, and the line of a stop of the take play.
extension StudioPreRollTests {
    /// The begin line, then the line with the parts of the seam term and H_T, before the save.
    @Test func journalHasThePreRollStart() async throws {
        let logs = package.folder.url.appending(path: "logs")
        let studio = try await studio()
        studio.environment.log = startLog(in: logs)
        try await studio.startRecording(armed: ["t1"], playhead: 96_000, preRoll: 1)
        try await studio.stopRecording()
        studio.log.drain()

        let rows = try journalLines(of: try #require(journalFiles(in: logs).first))
            .map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
            .filter { $0.count >= 6 }
        let events = rows.map { "\($0[4]) \($0[5])" }
        let begin = try #require(events.firstIndex(of: "take pre-roll-begin"), "\(events)")
        let line = try #require(events.firstIndex(of: "take pre-roll"), "\(events)")
        let save = try #require(events.firstIndex(of: "session save-begin"), "\(events)")
        #expect(begin < line && line < save, "\(events)")
        let fields = fieldValues(rows[line])
        #expect(fields["latency"] == "19" && fields["stream"] == "284" && fields["safety"] == "77", "\(fields)")
        #expect(fields["buffer"] == "512" && fields["rate"] == "48000", "\(fields)")
        #expect(fields["output"]?.wholeMatch(of: /uid-[0-9a-f]{8}/) != nil, "\(fields)")
        #expect(fields["start"] == "10000000000" && fields["ht"] == "11018583333", "\(fields)")
        #expect(fields["lead"] != nil, "\(fields)")
    }

    /// The parts of a device term are five fields and the UID a sixth; a manual term is one.
    @Test func preRollStartLineHasTheTermParts() {
        func text(_ value: DiagnosticValue) -> String {
            switch value {
            case .text(let text): text
            case .number(let number): "\(number)"
            case .milliseconds(let ms): "\(ms) ms"
            case .status(let status): "status \(status)"
            case .uid(let uid): "uid \(uid)"
            }
        }
        let device = preRollFields(
            lead: 518_583_333, realStart: 10_000_000_000, term: .builtIn, takeStart: 13_018_583_333)
        #expect(
            device.map { "\($0.key)=\(text($0.value))" } == [
                "lead=518.583333 ms", "start=10000000000", "latency=19", "stream=284", "safety=77", "buffer=512",
                "rate=48000", "output=uid out-uid", "ht=13018583333",
            ])
        let manual = preRollFields(lead: 500_000_000, realStart: 1, term: .manual(820), takeStart: 2)
        #expect(manual.map { "\($0.key)=\(text($0.value))" } == ["lead=500.0 ms", "start=1", "frames=820", "ht=2"])
    }

    /// No poll reads the take play, so the take stop writes its output change in the journal.
    @Test func takePlayStopHasAJournalLine() async throws {
        let logs = package.folder.url.appending(path: "logs")
        let studio = try await studio()
        studio.environment.log = startLog(in: logs)
        try await studio.startRecording(armed: ["t1"], playhead: 96_000, preRoll: 1)
        await studio.play.player?.outputChanged()
        try await studio.stopRecording()
        studio.log.drain()

        let stops = try journalLines(of: try #require(journalFiles(in: logs).first))
            .map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
            .filter { $0.count >= 6 && $0[4] == "take" && $0[5] == "pre-roll-stop" }.map(fieldValues)
        #expect(stops.map { $0["stop"] } == ["outputChanged"])
    }
}
