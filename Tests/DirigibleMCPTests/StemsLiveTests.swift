import AVFoundation
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio
@testable import DirigibleMCP

/// `export_stems` on a package that the app has open: it runs through `Studio.exportStems` in the one
/// export job (C12). Track `t1` plays clip `c1` and track `t2` plays clip `c2`, each the 3 s tone of
/// `addTone`, so each stem has three chunks.
@MainActor
struct StemsLiveTests {
    let package: LivePackage
    var out: URL { package.folder.appending(path: "Stems") }
    var arguments: [String: String] { ["package": package.path, "out": out.path] }
    let stopText = "A take started in Dirigible, so the stem export stopped. No stem was written."

    init() throws {
        package = try LivePackage()
        try package.addTone()
        var session = try Session(contentsOf: package.url)
        try session.place(Clip(id: "c2", file: "tone", start: 0, offset: 0, length: 144_000), on: "t2")
        try session.write(to: package.url)
    }

    /// The items beside the package, hidden items too.
    func outputs() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: package.folder.path).filter { $0 != "Show.dirigible" }
    }

    /// The file of `track` in a stem reply, from its stdout line.
    func file(of track: TrackID, in outcome: AgentBridge.Outcome) throws -> URL {
        guard case .reply(.result(let text, false)) = outcome else { throw POSIXError(.EINVAL) }
        let line = try #require(text.split(separator: "\n").first { $0.hasSuffix("\t\(track.rawValue)") })
        return out.appending(path: String(line.split(separator: "\t")[0]))
    }

    /// Opens the studio with its export held at chunk `hold`, and starts a server for it.
    func open(_ hold: ChunkHold) async throws -> (Studio, AgentServer, SocketFolder) {
        let studio = try await package.open()
        studio.environment.exportChunk = { hold.step() }
        let (server, folder) = try liveServer(studio)
        return (studio, server, folder)
    }

    /// A track gain of -60 dB that is not saved yet makes the stem of the track near silence.
    @Test func aLiveStemExportSeesTheUnsavedEdit() async throws {
        let studio = try await package.open()
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }
        let held = try await Self.unsavedEdit(studio)
        defer { held.gate.open() }

        let outcome = await send(folder.socket, "export_stems", arguments)

        #expect(try peak(of: file(of: "t1", in: outcome)) < 0.001, "\(outcome)")
        #expect(try peak(of: file(of: "t2", in: outcome)) > 0.05)
        #expect(try Session(contentsOf: package.url).track("t1")?.gain.dB == 0, "the edit is saved")
        held.gate.open()
        await held.task.value
        await studio.settle()
    }

    /// The job plans the stems on the session of its start: a mute after the media check of the call
    /// gives no file for the track.
    @Test func aMuteDuringTheMediaCheckGivesNoFileForTheTrack() async throws {
        let studio = try await package.open()
        let gate = Gate()
        defer { gate.open() }
        studio.environment.beforeMediaCheck = { await gate.wait() }
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }
        let (socket, arguments) = (folder.socket, arguments)
        let call = Task { await send(socket, "export_stems", arguments) }
        await until("the media check does not wait") { gate.waiting }

        try studio.edit(ripple: false) { session throws(SessionError) in try session.setMuted(true, tracks: ["t2"]) }
        gate.open()
        let outcome = await call.value

        _ = try file(of: "t1", in: outcome)
        guard case .reply(.result(let text, false)) = outcome else { throw POSIXError(.EINVAL) }
        #expect(!text.split(separator: "\n").contains { $0.hasSuffix("\tt2") }, "\(text)")
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).count == 1, "\(outcome)")
        await studio.settle()
    }

    /// The end that a take start runs ends a held stem export: no folder, no staging folder, and no
    /// lock file stay.
    @Test func aTakeStartEndsTheStemExport() async throws {
        let hold = ChunkHold(at: 2)
        defer { hold.release() }
        let (studio, server, folder) = try await open(hold)
        defer { server.stop() }
        let (socket, arguments) = (folder.socket, arguments)
        let call = Task { await send(socket, "export_stems", arguments) }
        await until("the stem export does not hold") { hold.isHeld }

        let end = Task { await studio.endExport(.take) }
        await until("the stop did not start") { studio.exportStop == .take }
        hold.release()
        await end.value
        let outcome = await call.value

        #expect(outcome == .reply(.result(text: stopText, isError: true)))
        #expect(try outputs() == [], "a stopped stem export left an item")
        await studio.settle()
    }

    /// The job URL is the target folder, so its parent exists while the stems render, and the disk
    /// check of a take in another window on that volume ends the stem export.
    @Test func aTakeInAnotherWindowEndsTheStemExport() async throws {
        let hold = ChunkHold(at: 2)
        defer { hold.release() }
        let (studio, server, folder) = try await open(hold)
        defer { server.stop() }
        let other = try LivePackage(name: "Other")
        let taking = try await other.open()
        taking.otherStudios = { [studio] }
        let (socket, arguments) = (folder.socket, arguments)
        let call = Task { await send(socket, "export_stems", arguments) }
        await until("the stem export does not hold") { hold.isHeld }

        let end = Task { await taking.endOtherExports(onVolumeOf: taking.lock) }
        await until("the take did not end the stem export") { studio.exportStop == .take }
        hold.release()
        let ended = await end.value
        let outcome = await call.value

        #expect(ended)
        #expect(outcome == .reply(.result(text: stopText, isError: true)))
        #expect(try outputs() == [], "a stopped stem export left an item")
        await taking.settle()
        await studio.settle()
    }

    /// A running stem export is the export of the window: an `export` call gets the busy text.
    @Test func aSecondExportIsBusy() async throws {
        let hold = ChunkHold(at: 2)
        defer { hold.release() }
        let (studio, server, folder) = try await open(hold)
        defer { server.stop() }
        let (socket, arguments) = (folder.socket, arguments)
        let call = Task { await send(socket, "export_stems", arguments) }
        await until("the stem export does not hold") { hold.isHeld }

        let mix = ["package": package.path, "out": package.folder.appending(path: "mix.wav").path]
        let busy = await send(socket, "export", mix)
        hold.release()
        let outcome = await call.value

        let text = "\(package.path) is busy in Dirigible: an export runs in its window. Try again later."
        #expect(busy == .reply(.result(text: text, isError: true)))
        _ = try file(of: "t1", in: outcome)
        #expect(!FileManager.default.fileExists(atPath: package.folder.appending(path: "mix.wav").path))
        await studio.settle()
    }

    /// A folder name over `stemFolderNameLimit` is refused before the job starts; the limit itself
    /// exports.
    @Test func aFolderNameOverTheLimitIsRefused() async throws {
        let studio = try await package.open()
        let source = try #require(ExportSource(range: 0..<144_000))
        let options = StemOptions(format: .wav(.bits24), layout: .mono, rate: .session)
        let (long, fits) = (
            package.folder.appending(path: String(repeating: "a", count: stemFolderNameLimit + 1)),
            package.folder.appending(path: String(repeating: "b", count: stemFolderNameLimit))
        )
        let number = studio.exportNumber

        await #expect(throws: StudioError.exportStems(.folderNameTooLong)) {
            try await studio.exportStems(by: .track, source: source, titles: .english, options: options, folder: long)
        }
        #expect(studio.exportNumber == number, "a job started")
        #expect(try outputs() == [], "the refusal left an item")
        let result = try await studio.exportStems(
            by: .track, source: source, titles: .english, options: options, folder: fits)
        #expect(result.files.count == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fits.path).count == 2)
        await studio.settle()
    }

    /// With the agent server off, the tool exports the saved files with no lock: the unsaved edit
    /// is not in them.
    @Test func withTheServerOffTheToolExportsTheSavedFiles() async throws {
        let studio = try await package.open()
        let held = try await Self.unsavedEdit(studio)
        defer { held.gate.open() }
        let tool = try #require(Tool.all.first { $0.name == "export_stems" })
        let control = CallControl(token: nil, interval: .zero, send: { _ in }, poll: { _ in false }, step: {})
        let arguments = arguments

        let answer = await onThread { tool.call(arguments, control: control) }

        #expect(!answer.1, "\(answer)")
        let outcome = AgentBridge.Outcome.reply(.result(text: answer.0, isError: false))
        #expect(try peak(of: file(of: "t1", in: outcome)) > 0.05, "the export read the unsaved edit")
        held.gate.open()
        await held.task.value
        await studio.settle()
    }

    /// Holds the write turn, so the autosave waits, then sets a track gain of -60 dB on `t1`.
    static func unsavedEdit(_ studio: Studio) async throws -> (gate: Gate, task: Task<Void, Never>) {
        let gate = Gate()
        let task = Task { await studio.serialized { await gate.wait() } }
        await until("the write turn is not held") { gate.waiting }
        try studio.edit(ripple: false) { session throws(SessionError) in
            try session.setGain(Gain(dB: -60)!, track: "t1")
        }
        return (gate, task)
    }
}

/// The sample peak of the audio file at `url`, over all its channels.
private func peak(of url: URL) throws -> Float {
    let file = try AVAudioFile(forReading: url)
    let buffer = try #require(
        AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: buffer)
    let channels = try #require(buffer.floatChannelData)
    return (0..<Int(buffer.format.channelCount)).map { channel in
        (0..<Int(buffer.frameLength)).reduce(Float(0)) { max($0, abs(channels[channel][$1])) }
    }.max() ?? 0
}
