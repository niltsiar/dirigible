import AVFoundation
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio
@testable import DirigibleMCP

/// `clip_denoise` on a package that the app has open: it runs through `Studio.renderClips`
/// (decisions 0049 and 0054, criterion C12). Track `t3` "Voice" (mono) holds clip `n1` of 3 s of
/// `nv.wav`, so the render has three blocks.
@MainActor
struct LiveDenoiseTests {
    let package: LivePackage
    var clips: URL { package.url.appending(path: "Clips") }
    var arguments: [String: any Sendable] { ["package": package.path, "clips": ["n1"]] }

    init() throws {
        package = try LivePackage()
        var session = try Session(contentsOf: package.url)
        try session.addFile(AudioFile(id: "nv", path: "nv.wav", layout: .mono, length: 144_000))
        try session.addTrack("t3", name: "Voice", layout: .mono)
        try session.place(Clip(id: "n1", file: "nv", start: 0, offset: 0, length: 144_000), on: "t3")
        try session.write(to: package.url)
        try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let file = try AVAudioFile(forWriting: clips.appending(path: "nv.wav"), settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 144_000))
        buffer.frameLength = 144_000
        for frame in 0..<144_000 { buffer.floatChannelData![0][frame] = Float(0.1 * sin(Double(frame) / 8)) }
        try file.write(from: buffer)
    }

    func names() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: clips.path).sorted() }

    /// The reply is the line of the clip, the clip plays the new file, and the render is one undo
    /// step with the agent name that keeps the WAV.
    @Test func renderRunsInTheStudio() async throws {
        let studio = try await package.open()
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }

        let outcome = await send(folder.socket, "clip_denoise", arguments)

        let session = studio.session
        let file = try #require(session.clip("n1")?.clip.file)
        #expect(file != "nv", "the clip stays on nv")
        let lines = ClipRenderWork.lines([RenderedClip(clip: "n1", file: file)])
        #expect(outcome == .reply(.result(text: lines.joined(separator: "\n"), isError: false)), "\(outcome)")
        #expect(studio.undoAgent?.name == "Test Agent")
        let files = ["nv NR.wav", "nv.wav"]
        #expect(try names() == files)
        try studio.undo()
        #expect(studio.session.clip("n1")?.clip.file == "nv" && !studio.canUndo)
        let afterUndo = try names()
        #expect(afterUndo == files, "Undo keeps the WAV")
        await studio.settle()
    }

    /// C20: `hum` with `noise` false runs in the Studio as one undo step, and the clip plays the
    /// ` HR` file.
    @Test func humRunsInTheStudio() async throws {
        let studio = try await package.open()
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }

        let outcome = await send(folder.socket, "clip_denoise", arguments.merging(["hum": 50, "noise": false]) { $1 })

        let file = try #require(studio.session.clip("n1")?.clip.file)
        let lines = ClipRenderWork.lines([RenderedClip(clip: "n1", file: file)])
        #expect(outcome == .reply(.result(text: lines.joined(separator: "\n"), isError: false)), "\(outcome)")
        #expect(studio.session.files[file]?.path == "nv HR.wav", "the clip plays \(file)")
        #expect(try names() == ["nv HR.wav", "nv.wav"])
        try studio.undo()
        #expect(studio.session.clip("n1")?.clip.file == "nv" && !studio.canUndo)
        await studio.settle()
    }

    /// The Cancel of the banner ends an agent render with no clip changed and no new WAV, and the
    /// agent gets the text of the user cancel.
    @Test func cancelChangesNoClip() async throws {
        let hold = ChunkHold(at: 2)
        defer { hold.release() }
        let studio = try await package.open()
        studio.environment.importStep = { hold.step() }
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }
        let (socket, arguments) = (folder.socket, arguments)
        let call = Task { await send(socket, "clip_denoise", arguments) }
        await until("the render does not hold") { hold.isHeld }

        studio.cancelImport()
        hold.release()
        let outcome = await call.value

        let text = "The user cancelled the noise reduction in Dirigible. No clip changed."
        #expect(outcome == .reply(.result(text: text, isError: true)), "\(outcome)")
        #expect(studio.session.clip("n1")?.clip.file == "nv" && !studio.canUndo)
        #expect(try names() == ["nv.wav"], "a cancelled render left a file")
        await studio.settle()
    }

    /// A take start in another studio ends the render with the take text.
    @Test func takeStartStopsTheRender() async throws {
        let hold = ChunkHold(at: 2)
        defer { hold.release() }
        let studio = try await package.open()
        studio.environment.importStep = { hold.step() }
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }
        let (socket, arguments) = (folder.socket, arguments)
        let call = Task { await send(socket, "clip_denoise", arguments) }
        await until("the render does not hold") { hold.isHeld }

        studio.endImport(.take)
        hold.release()
        let outcome = await call.value

        let text = "A take started in Dirigible, so the noise reduction stopped. No clip changed."
        #expect(outcome == .reply(.result(text: text, isError: true)), "\(outcome)")
        #expect(studio.session.clip("n1")?.clip.file == "nv" && !studio.canUndo)
        #expect(try names() == ["nv.wav"], "a stopped render left a file")
        await studio.settle()
    }
}
