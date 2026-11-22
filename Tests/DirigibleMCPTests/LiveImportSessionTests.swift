import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio
@testable import DirigibleMCP

/// `import_session` on a package that the app has open: it runs through `Studio.importSession`
/// (decisions 0049 and 0075, C11). The source is a closed package "Guest" with the 3 s tone on
/// its track Host.
@MainActor
struct LiveImportSessionTests {
    let package: LivePackage
    let source: LivePackage

    init() throws {
        package = try LivePackage()
        source = try LivePackage(name: "Guest")
        try source.addTone()
        FileManager.default.createFile(atPath: source.url.appending(path: ".lock").path, contents: nil)
    }

    func names() throws -> [String] {
        let clips = package.url.appending(path: "Clips")
        return ((try? FileManager.default.contentsOfDirectory(atPath: clips.path)) ?? []).sorted()
    }

    /// The reply is the new track IDs in source order, the import is one undo step with the agent
    /// name, and Undo removes the new tracks and keeps the copied WAV as an unused file.
    @Test func aLiveSessionImportIsOneUndoStepOfTheAgent() async throws {
        let studio = try await package.open()
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }
        let old = studio.session.tracks.map(\.id)

        let outcome = await send(folder.socket, "import_session", ["package": package.path, "source": source.path])

        let new = studio.session.tracks.map(\.id).filter { !old.contains($0) }
        #expect(new.count == 2, "\(studio.session.tracks.map(\.name))")
        #expect(outcome == .reply(.result(text: new.map(\.rawValue).joined(separator: "\n"), isError: false)))
        #expect(
            studio.session.tracks.map(\.name) == ["Host", "Music", "Host (Guest)", "Music (Guest)"],
            "\(studio.session.tracks.map(\.name))")
        #expect(studio.undoAgent?.name == "Test Agent")
        let copied = try names()
        #expect(copied.count == 1, "\(copied)")
        try studio.undo()
        #expect(studio.session.tracks.map(\.id) == old && !studio.canUndo, "one undo step removes the new tracks")
        #expect(try names() == copied, "the copied WAV stays after Undo")
        await studio.settle()
    }

    /// With markers, the reply has a `marker <ID>` line for each new marker after the track IDs,
    /// then the line with the count of the markers that the offset leaves out.
    @Test func aLiveImportReportsTheMarkers() async throws {
        var marked = try Session(contentsOf: source.url)
        try marked.setMarker(Marker(id: "early", name: "Early", position: 1_000, kind: .marker))
        try marked.setMarker(Marker(id: "late", name: "Late", position: 30_000, kind: .chapter))
        try marked.write(to: source.url)
        let studio = try await package.open()
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }
        let old = studio.session.tracks.map(\.id)

        let outcome = await send(
            folder.socket, "import_session",
            ["package": package.path, "source": source.path, "markers": true, "at": -24_000])

        let new = studio.session.tracks.map(\.id).filter { !old.contains($0) }
        let late = try #require(studio.session.sortedMarkers.first { $0.name == "Late" })
        #expect(late.position == 6_000 && studio.session.markers.count == 1)
        let lines =
            new.map(\.rawValue) + [
                "marker \(late.id.rawValue)", "Left out: 1 marker before frame 0 or after frame 2^40.",
            ]
        #expect(outcome == .reply(.result(text: lines.joined(separator: "\n"), isError: false)), "\(outcome)")
        await studio.settle()
    }

    /// A refused source gives the text of the command and changes nothing.
    @Test func aLiveImportOfTheOpenSessionIsRefused() async throws {
        let studio = try await package.open()
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }
        let before = studio.session

        let outcome = await send(folder.socket, "import_session", ["package": package.path, "source": package.path])

        let text =
            "\(package.path) is the same session as \(package.path), so Dirigible does not import it. "
            + "Give a different source."
        #expect(outcome == .reply(.result(text: text, isError: true)), "\(outcome)")
        #expect(studio.session == before && !studio.canUndo)
        await studio.settle()
    }
}
