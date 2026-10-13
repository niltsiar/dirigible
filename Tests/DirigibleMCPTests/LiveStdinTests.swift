import AVFoundation
import Foundation
import Testing

@testable import DirigibleCore
@testable import DirigibleMCP

/// A cancel that comes on a live stdin while a job runs (decision 0049, C21). `MCPServer` reads a
/// `LineInput` on a `Pipe` in this process, and the step of each `CallControl` holds the job after
/// its first progress line, so the cancel comes while the job still runs.
@MainActor
struct LiveStdinTests {
    /// The stdout lines of the server, and the hold of its job.
    final class Run: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        private var holding = false
        private var ended = false
        private let hold = DispatchSemaphore(value: 0)

        func send(_ line: String) { lock.withLock { lines.append(line) } }
        var all: [[String: Any]] {
            lock.withLock { lines }.compactMap {
                (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
            }
        }
        var isHolding: Bool { lock.withLock { holding } }
        var isEnded: Bool { lock.withLock { ended } }
        func end() { lock.withLock { ended = true } }

        /// The step of the job: after the first progress line, it waits once for `release`.
        func step() {
            let first = lock.withLock {
                guard !holding, lines.contains(where: { $0.contains("notifications/progress") }) else { return false }
                holding = true
                return true
            }
            if first { hold.wait() }
        }

        func release() { hold.signal() }
    }

    /// Runs the server loop of `dirigible mcp` on a new thread, on the read end of `stdin`.
    private func serve(_ stdin: Pipe, _ run: Run) {
        let fd = stdin.fileHandleForReading.fileDescriptor
        Thread.detachNewThread {
            let input = LineInput(fd: fd)
            var server = MCPServer(
                send: run.send, pollCancel: input.pollCancel, pollInterval: .zero, step: run.step)
            while let line = input.next() {
                if let answer = server.answer(line) { run.send(answer) }
            }
            run.end()
        }
    }

    private func write(_ stdin: Pipe, _ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        stdin.fileHandleForWriting.write(data + Data("\n".utf8))
    }

    private func package() throws -> LivePackage {
        let package = try LivePackage()
        try package.addTone()
        return package
    }

    /// Runs a `name` call with id 2 and a token, cancels it after its first progress line, then
    /// sends a `ping` with id 3. Gives the stdout lines.
    private func cancelled(_ name: String, _ arguments: [String: Any]) async throws -> [[String: Any]] {
        let (stdin, run) = (Pipe(), Run())
        defer { run.release() }
        serve(stdin, run)
        try write(
            stdin,
            [
                "jsonrpc": "2.0", "id": 2, "method": "tools/call",
                "params": ["name": name, "arguments": arguments, "_meta": ["progressToken": 1]],
            ])
        await until("the job holds after its first progress line") { run.isHolding }
        try write(stdin, ["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 2]])
        run.release()
        try write(stdin, ["jsonrpc": "2.0", "id": 3, "method": "ping"])
        try stdin.fileHandleForWriting.close()
        await until("the server ends at the end of stdin") { run.isEnded }
        // The pipe closes its read end when it goes, so it lives until the server thread ends.
        withExtendedLifetime(stdin) {}
        let lines = run.all
        #expect(lines.contains { $0["id"] as? Int == 3 }, "the ping after the cancel has its answer: \(lines)")
        #expect(!lines.contains { $0["id"] as? Int == 2 }, "a cancelled \(name) has no answer: \(lines)")
        return lines
    }

    @Test func aLiveCancelEndsTheLoudness() async throws {
        let package = try package()
        _ = try await cancelled("loudness", ["package": package.path])
    }

    /// The export of 3 s has three chunks; the cancel comes after the first one. No file stays.
    @Test func aLiveCancelEndsTheExport() async throws {
        let package = try package()
        let out = package.folder.appending(path: "mix.wav")
        _ = try await cancelled("export", ["package": package.path, "out": out.path])
        let left = try FileManager.default.contentsOfDirectory(atPath: package.folder.path)
        #expect(left == ["Show.dirigible"], "a cancelled export left a file: \(left)")
    }
}

extension LivePackage {
    /// Adds clip `c1` of 3 s of a tone on `t1`: three blocks of `clipLoudness`.
    func addTone() throws {
        var session = try Session(contentsOf: url)
        try session.addFile(AudioFile(id: "tone", path: "tone.wav", layout: .mono, length: 144_000))
        try session.place(Clip(id: "c1", file: "tone", start: 0, offset: 0, length: 144_000), on: "t1")
        try session.write(to: url)
        let clips = url.appending(path: "Clips")
        try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let file = try AVAudioFile(forWriting: clips.appending(path: "tone.wav"), settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 144_000))
        buffer.frameLength = 144_000
        for frame in 0..<144_000 { buffer.floatChannelData![0][frame] = Float(0.1 * sin(Double(frame) / 8)) }
        try file.write(from: buffer)
    }
}
