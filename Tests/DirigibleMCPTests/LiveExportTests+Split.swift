import DirigibleCore
import Foundation
import Testing
import os

@testable import DirigibleAudio
@testable import DirigibleMCP

/// `export` with `split` on a package that the app has open (decision 0067, criterion C14). The package
/// of `LiveExportTests` with the chapters Intro at 0, Second at 1 s, and Third at 2 s, so the stem `Ep`
/// gives `Ep-01-Intro.wav`, `Ep-02-Second.wav`, and `Ep-03-Third.wav`.
extension LiveExportTests {
    var stem: URL { package.folder.appending(path: "Ep.wav") }
    var setArguments: [String: String] { ["package": package.path, "out": stem.path, "split": "chapters"] }

    func file(_ number: Int) -> String {
        package.folder.appending(path: ["Ep-01-Intro", "Ep-02-Second", "Ep-03-Third"][number - 1] + ".wav").path
    }

    func addChapters() throws {
        var session = try Session(contentsOf: package.url)
        for (id, name, position) in [("a", "Intro", 0), ("b", "Second", 48_000), ("c", "Third", 96_000)] {
            try session.setMarker(Marker(id: MarkerID(id), name: name, position: Frames(position), kind: .chapter))
        }
        try session.write(to: package.url)
    }

    /// Opens the studio with its export held once in part 2, and starts a server for it.
    func openHeldInPartTwo(sheetCause: @escaping @MainActor () -> AgentBusy? = { nil }) async throws -> (
        Studio, AgentServer, SocketFolder, PartHold
    ) {
        try addChapters()
        let hold = PartHold(folder: package.folder, prefix: ".Ep-02")
        let studio = try await package.open()
        studio.environment.exportChunk = { hold.step() }
        let (server, folder) = try liveServer(studio, sheetCause: sheetCause)
        return (studio, server, folder, hold)
    }

    @Test func aLiveSplitExportRunsInTheWindowJob() async throws {
        let (studio, server, folder, hold) = try await openHeldInPartTwo()
        defer {
            hold.release()
            server.stop()
        }
        let (socket, arguments) = (folder.socket, setArguments)
        let call = Task { await send(socket, "export", arguments) }
        await until("the set does not hold in part 2") { hold.isHeld }
        await until("the window has no file in hand") { studio.exportFile?.number == 2 }

        #expect(studio.exportFile?.count == 3 && studio.exportFile?.name == "Ep-02-Second.wav")
        #expect(studio.exportProgress != nil, "the set is the one export job of the window")
        hold.release()
        let outcome = await call.value

        let text = (1...3).map(file).joined(separator: "\n")
        #expect(outcome == .reply(.result(text: text, isError: false)))
        #expect(studio.exportProgress == nil)
        await studio.settle()
    }

    /// C14, H1: Cancel in the sheet during part 2 keeps part 1 and names the files not written.
    @Test func aCancelledLiveSetNamesTheWrittenFiles() async throws {
        let (studio, server, folder, hold) = try await openHeldInPartTwo()
        defer {
            hold.release()
            server.stop()
        }
        let (socket, arguments) = (folder.socket, setArguments)
        let call = Task { await send(socket, "export", arguments) }
        await until("the set does not hold in part 2") { hold.isHeld }

        let end = Task { studio.cancelExport() }
        await until("the stop did not start") { studio.exportStop == .user }
        hold.release()
        await end.value
        let outcome = await call.value

        let sentence =
            "The user cancelled the export in Dirigible. 1 file was written; 2 files were not written: "
            + "\(file(2)), \(file(3))."
        #expect(outcome == .reply(.result(text: file(1) + "\n" + sentence, isError: true)))
        #expect(try outputs().sorted() == ["Ep-01-Intro.wav"], "part 1 stays; no temporary file")
        await studio.settle()
    }

    @Test func aServerStopOfASetSaysTheWrittenFilesStay() async throws {
        let (studio, server, folder, hold) = try await openHeldInPartTwo()
        defer { hold.release() }
        let (socket, arguments) = (folder.socket, setArguments)
        let call = Task { await send(socket, "export", arguments) }
        await until("the set does not hold in part 2") { hold.isHeld }

        server.stop()
        hold.release()
        let outcome = await call.value

        let text =
            "Dirigible stopped its agent server, so the export stopped. The files that were written before the "
            + "stop stay in \(package.folder.path)."
        #expect(outcome == .reply(.result(text: text, isError: true)))
        await studio.settle()
    }

    /// Lead ruling 1b row 7: the chapters go after the check of the caller and before the job. The job
    /// finds no point, writes nothing, and the text is the one of the CLI.
    @Test func aDeletedPointBeforeTheLiveJobGivesTheNoChapterText() async throws {
        try addChapters()
        let studio = try await package.open()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let (server, folder) = try liveServer(studio) {
            // The first call is the check of the bridge, the second the one after the media check.
            if calls.withLock({
                $0 += 1
                return $0
            }) == 2 {
                try? studio.edit(ripple: false) { session throws(SessionError) in
                    for id in ["a", "b", "c"] { try session.removeMarker(MarkerID(id)) }
                }
            }
            return nil
        }
        defer { server.stop() }

        let outcome = await send(folder.socket, "export", setArguments)

        #expect(outcome == .reply(.result(text: "no chapter in frames 0..<144000.", isError: true)))
        #expect(try outputs() == [], "the set wrote a file")
        await studio.settle()
    }

    /// Fix check: a chapter renamed after the check of the caller gives a target that the caller did not
    /// confirm. The set stops before part 1, and the text names the file.
    @Test func aRenameBeforeTheLiveJobNamesTheExistingFile() async throws {
        try addChapters()
        let existing = package.folder.appending(path: "Ep-02-Renamed.wav")
        try Data("keep".utf8).write(to: existing)
        let studio = try await package.open()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let (server, folder) = try liveServer(studio) {
            if calls.withLock({
                $0 += 1
                return $0
            }) == 2 {
                try? studio.edit(ripple: false) { session throws(SessionError) in
                    try session.setMarker(Marker(id: "b", name: "Renamed", position: 48_000, kind: .chapter))
                }
            }
            return nil
        }
        defer { server.stop() }

        let outcome = await send(folder.socket, "export", setArguments)

        let text = "1 file exists: \(existing.path). Use replace to replace it."
        #expect(outcome == .reply(.result(text: text, isError: true)))
        #expect(try outputs() == ["Ep-02-Renamed.wav"], "a part was written")
        #expect(try Data(contentsOf: existing) == Data("keep".utf8))
        await studio.settle()
    }
}

/// Holds the export of a studio once, in the chunk loop of the part whose temporary file starts
/// with `prefix` in `folder`, until `release`.
final class PartHold: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private let (folder, prefix): (URL, String)
    private var held = false

    init(folder: URL, prefix: String) { (self.folder, self.prefix) = (folder, prefix) }

    var isHeld: Bool { lock.withLock { held } }

    func step() {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let hold = lock.withLock {
            guard !held, items.contains(where: { $0.hasPrefix(prefix) }) else { return false }
            held = true
            return true
        }
        if hold { semaphore.wait() }
    }

    /// A second release leaves the semaphore at 1, which no later step reads.
    func release() { semaphore.signal() }
}
