import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio
@testable import DirigibleMCP

/// `dirigible transport play`, `stop`, and `locate` (run agent-transport, C15): the binary sends
/// its call over `DIRIGIBLE_MCP_SOCKET` to an `AgentServer` with a studio in this process. The
/// package has clip `c1` of 144 000 frames (3 s at 48 kHz), and the Player renders offline.
@MainActor
struct TransportCommandTests {
    let package: TemporaryPackage
    let forward = Shuttle(direction: .forward, rate: .one)
    /// The path that the app compares: absolute and standardized.
    var path: String { package.url.standardizedFileURL.path }

    init() throws {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "f1", path: "f1.wav", layout: .mono, length: 144_000))
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.place(Clip(id: "c1", file: "f1", start: 0, offset: 0, length: 144_000), on: "t1")
        package = try TemporaryPackage(session)
        try FileManager.default.createDirectory(
            at: package.url.appending(path: "Clips"), withIntermediateDirectories: true)
        try RenderCommandTests.writeWAV(package.url.appending(path: "Clips/f1.wav"), frames: 144_000)
    }

    /// The studio of the package at `path`, and a server for it on a short socket path.
    func open(_ target: String? = nil) async throws -> (Studio, AgentServer, URL) {
        let studio = try await Studio.open(URL(filePath: target ?? path))
        studio.environment.playerOutput = .offline
        var template = Array("/tmp/dmcp-XXXXXX".utf8CString)
        let folder = try #require(mkdtemp(&template).map { URL(filePath: String(cString: $0)) })
        let server = AgentServer(socket: folder.appending(path: "mcp.sock")) { [AgentTarget(studio: studio)] }
        server.start()
        return (studio, server, folder)
    }

    @Test func playThroughTheSocket() async throws {
        let (studio, server, folder) = try await open()
        defer { server.stop() }
        defer { try? FileManager.default.removeItem(at: folder) }

        let result = try await dirigible(
            ["transport", "play", path, "--from", "24000", "--to", "50000"], socket: folder.appending(path: "mcp.sock"))

        #expect(result == CLIResult(status: 0, stdout: "Playing from 24000 to 50000.\n", stderr: ""))
        #expect(studio.playback == .playing(forward))
        await studio.settle()
    }

    @Test func stopThroughTheSocket() async throws {
        let (studio, server, folder) = try await open()
        defer { server.stop() }
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try await studio.play(from: 24_000, to: 50_000)

        let result = try await dirigible(["transport", "stop", path], socket: folder.appending(path: "mcp.sock"))

        #expect(studio.playback == .stopped)
        #expect(result == CLIResult(status: 0, stdout: "Stopped at \(studio.playhead.count).\n", stderr: ""))
    }

    @Test func locateThroughTheSocket() async throws {
        let (studio, server, folder) = try await open()
        defer { server.stop() }
        defer { try? FileManager.default.removeItem(at: folder) }

        let result = try await dirigible(
            ["transport", "locate", path, "5000"], socket: folder.appending(path: "mcp.sock"))

        #expect(result == CLIResult(status: 0, stdout: "Stopped at 5000.\n", stderr: ""))
        #expect(studio.playhead == 5000)
    }

    /// The app matches the package by its absolute path, so the command resolves `Show.dirigible`
    /// against its working folder before it sends the call.
    @Test func aRelativePackagePathReachesTheApp() async throws {
        let (studio, server, folder) = try await open()
        defer { server.stop() }
        defer { try? FileManager.default.removeItem(at: folder) }

        let result = try await dirigible(
            ["transport", "play", "Show.dirigible", "--from", "24000"], socket: folder.appending(path: "mcp.sock"),
            directory: package.folder)

        #expect(result == CLIResult(status: 0, stdout: "Playing from 24000 to 144000.\n", stderr: ""), "\(result)")
        #expect(studio.playback == .playing(forward))
        await studio.settle()
    }

    /// An error reply of the app (here a take) goes to stderr with exit 1.
    @Test func anErrorReplyExitsOne() async throws {
        let (studio, server, folder) = try await open()
        defer { server.stop() }
        defer { try? FileManager.default.removeItem(at: folder) }
        studio.transport = .recording(take: 1)
        defer { studio.transport = .idle }

        let result = try await dirigible(["transport", "stop", path], socket: folder.appending(path: "mcp.sock"))

        let text = "\(path) records a take in Dirigible. transport_stop stops only a play; the user stops the take in "
        #expect(result == CLIResult(status: 1, stdout: "", stderr: "Error: " + text + "Dirigible.\n"), "\(result)")
    }

    /// With no app at the socket, the call runs on the files, which refuse it.
    @Test func noAppGivesTheFilesText() async throws {
        let result = try await dirigible(["transport", "locate", path, "10"])

        let text = "To play, stop, or locate, open \(path) in Dirigible and turn on Let Agents Edit Open Sessions in "
        #expect(result == CLIResult(status: 1, stdout: "", stderr: "Error: " + text + "Settings.\n"), "\(result)")
    }

    @Test func toEqualToFromExits64() async throws {
        let result = try await dirigible(["transport", "play", path, "--from", "5", "--to", "5"])

        #expect(result.status == 64 && result.stdout.isEmpty, "\(result)")
        #expect(result.stderr.contains("--to must be more than --from."), "\(result)")
    }
}
