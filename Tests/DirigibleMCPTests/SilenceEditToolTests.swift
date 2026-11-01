import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio
@testable import DirigibleMCP

/// `silence_edit` on a package that the app has open (decision 0066, criterion C26). Tracks `t1`
/// and `t2` each play file `f` of 480 000 frames from frame 0 as one clip. Silence A is 96 000 ..<
/// 240 000 and silence B is 264 000 ..< 312 000.
@MainActor
struct SilenceEditToolTests {
    static let plan: [String: any Sendable] = [
        "from": [96_000, 264_000], "to": [240_000, 312_000], "action": ["shorten", "mark"],
    ]

    func makePackage() throws -> LivePackage {
        let package = try LivePackage()
        var session = try Session(contentsOf: package.url)
        try session.addFile(AudioFile(id: "f", path: "f.wav", layout: .mono, length: 480_000))
        for track in ["t1", "t2"] as [TrackID] {
            let clip = Clip(id: ClipID("c-\(track)"), file: "f", start: 0, offset: 0, length: 480_000)
            try session.place(clip, on: track)
        }
        try session.write(to: package.url)
        return package
    }

    /// The tool edits the window as one undo entry of the agent and gives the lines of the
    /// command. Fail value: an edit for each pair, which is two undo entries.
    @Test func theToolEditsTheWindowAsOneUndoEntry() async throws {
        let package = try makePackage()
        let studio = try await package.open()
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }
        let (before, revision) = (studio.session, studio.sessionRevision)

        let outcome = await send(folder.socket, "silence_edit", Self.plan.merging(["package": package.path]) { $1 })

        let lines = replyText(outcome).split(separator: "\n").map(String.init)
        #expect(lines.count == 3 && lines.first == "shorten\t96000\t240000\t108000\t228000", "\(lines)")
        #expect(lines.last == "removed 120000 frames")
        let mark = lines[1].split(separator: "\t").map(String.init)
        #expect(Array(mark.prefix(3)) == ["mark", "264000", "312000"], "\(lines[1])")
        #expect(studio.session.track("t1")?.clips.map(\.range) == [0..<108_000, 108_000..<360_000])
        #expect(studio.session.markers[MarkerID(mark[3])]?.position == 168_000)
        #expect(studio.sessionRevision == revision + 1, "one call is one edit")
        #expect(studio.undoAgent == AgentName(title: "Test Agent", clientName: nil))
        try studio.undo()
        let undone = studio.session == before
        #expect(undone && !studio.canUndo, "one undo gives back the session before the call")
        await studio.settle()
    }

    /// During a take the tool gives the busy text and changes nothing.
    @Test func aBusyWindowRefusesTheTool() async throws {
        let package = try makePackage()
        let studio = try await package.open()
        let (server, folder) = try liveServer(studio, busy: .task)
        defer { server.stop() }
        let before = studio.session

        let outcome = await send(folder.socket, "silence_edit", Self.plan.merging(["package": package.path]) { $1 })

        let text = AgentBusy.task.message(package: package.path)
        #expect(outcome == .reply(.result(text: text, isError: true)), "\(outcome)")
        #expect(studio.session == before && !studio.canUndo)
        await studio.settle()
    }

    /// Under a pending take a plan with a shorten gives the ripple refusal and changes nothing,
    /// and a plan of marks runs (decision 0037).
    @Test func aPendingTakeRefusesAShortenAndAllowsAMark() async throws {
        let package = try makePackage()
        try package.addPendingTake()
        let studio = try await package.open(pending: 1)
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }
        let before = studio.session

        let shorten = await send(folder.socket, "silence_edit", Self.plan.merging(["package": package.path]) { $1 })
        let text = StudioError.rippleBlocked.message(package: package.path)
        #expect(shorten == .reply(.result(text: text, isError: true)), "\(shorten)")
        #expect(studio.session == before)

        let mark = await send(
            folder.socket, "silence_edit",
            ["package": package.path, "from": [1_000], "to": [3_000], "action": ["mark"]])
        #expect(replyText(mark).hasPrefix("mark\t1000\t3000\t"), "\(mark)")
        #expect(studio.session.markers.values.map(\.position) == [2_000])
        await studio.settle()
    }
}
