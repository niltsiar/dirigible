import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio
@testable import DirigibleMCP

/// `chapters_import` on a package that the app has open (C20, C21, C24b of run
/// 2026-10-17-agent-pack): one undo entry, and no entry for a bad file.
@MainActor
struct LiveChaptersImportTests {
    let package: LivePackage
    let image = try! ArtworkName("0B3C5B2E-6F1A-4D2B-9E57-1C8F2A9D4E60.jpg")

    init() throws {
        package = try LivePackage()
        var session = try Session(contentsOf: package.url)
        try session.setMarker(Marker(id: "old", name: "Outro", position: 576_000, kind: .chapter, image: image))
        try session.write(to: package.url)
    }

    func write(_ json: String, name: String = "chapters.json") throws -> String {
        let url = package.folder.appending(path: name)
        try Data(json.utf8).write(to: url)
        return url.path
    }

    /// C21: three chapters are one edit with the agent name; one undo gives the session back.
    @Test func aLiveChaptersImportIsOneUndoEntry() async throws {
        let studio = try await package.open()
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }
        let path = try write(
            #"{"version": "1.2.0", "chapters": [{"startTime": 0}, {"startTime": 12, "title": "Closing"}, {"startTime": 30}]}"#
        )
        let (before, revision) = (studio.session, studio.sessionRevision)

        let outcome = await send(
            folder.socket, "chapters_import", ["package": package.path, "path": path, "replace": true])

        let ids = replyText(outcome).split(separator: "\n").map { MarkerID(String($0)) }
        #expect(ids.count == 3, "\(outcome)")
        #expect(studio.sessionRevision == revision + 1, "one call is one edit")
        #expect(studio.undoAgent == AgentName(title: "Test Agent", clientName: nil))
        #expect(studio.session.markers.count == 3 && studio.session.markers["old"] == nil)
        #expect(ids.compactMap { studio.session.markers[$0]?.image } == [image], "the image stays at 12 s")
        try studio.undo()
        let undone = studio.session == before
        #expect(undone, "one undo gives back the session before the call")
        await studio.settle()
    }

    /// C20, C24b: a bad file, and an import that would drop an image, give an error and no undo entry.
    @Test func aLiveChaptersImportOfABadFileAddsNoUndoEntry() async throws {
        let studio = try await package.open()
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }
        let (before, revision) = (studio.session, studio.sessionRevision)
        let broken = try write("not json", name: "broken.json")
        let drop = try write(
            #"{"version": "1.2.0", "chapters": [{"startTime": 0}, {"startTime": 20}]}"#, name: "drop.json")

        let bad = await send(folder.socket, "chapters_import", ["package": package.path, "path": broken])
        let refused = await send(
            folder.socket, "chapters_import", ["package": package.path, "path": drop, "replace": true])

        #expect(bad == .reply(.result(text: "\(broken): the file is not a JSON object.", isError: true)))
        let text =
            "the import would drop the image of \"Outro\" at 576000. The file has no chapter at the same time. "
            + "Remove the chapter first, or add one at that time to the file."
        #expect(refused == .reply(.result(text: text, isError: true)))
        #expect(studio.sessionRevision == revision && !studio.canUndo && studio.session == before)
        await studio.settle()
    }
}
