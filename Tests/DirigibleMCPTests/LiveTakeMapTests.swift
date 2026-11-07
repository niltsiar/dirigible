import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio
@testable import DirigibleMCP

/// `take_map` and the sync key of `session_info` on a package that the app has open (decision
/// 0061, C6). The studio answers with the anchors of its open, so the call reads no file.
@MainActor
struct LiveTakeMapTests {
    /// Take 1 on `t1` at 0, with its anchor from the real writer: origin 0, so the clip at 96 000
    /// plays take frame 0 at 96 000.
    static func takePackage() throws -> LivePackage {
        let package = try LivePackage()
        var session = try Session(contentsOf: package.url)
        try session.addCapture(
            Capture(
                id: "take1-1-1", deviceUID: "usb-1", deviceName: "USB Mic", hostTimeNanos: takeStart, sampleTime: 0,
                nominalSampleRate: 48_000, measuredSampleRate: 48_000, latency: 0, resampledFromRate: nil,
                driftCorrected: true))
        try session.addFile(
            AudioFile(id: "take1-1-1", path: "take1-1-1.wav", layout: .mono, length: 48_000, capture: "take1-1-1"))
        try session.place(Clip(id: "c1", file: "take1-1-1", start: 96_000, offset: 0, length: 48_000), on: "t1")
        try session.write(to: package.url)
        try FileManager.default.createDirectory(
            at: package.url.appending(path: "Capture"), withIntermediateDirectories: true)
        try TakeAnchor.write(
            Recording(take: 1, playheadFrame: 96_000, takeStartHostTimeNanos: takeStart, armedTracks: ["t1"]),
            in: package.url)
        return package
    }

    @Test func takeMapReadsTheStudio() async throws {
        let package = try Self.takePackage()
        let studio = try await package.open()
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }
        // A live edit that the files do not have: the map follows the studio session.
        try studio.edit(ripple: true) { session throws(SessionError) in
            try session.rippleInsert(1000, at: 0, on: ["t1", "t2"], naming: [])
        }

        let map = await send(folder.socket, "take_map", ["package": package.path, "frames": [10]])
        let info = await send(folder.socket, "session_info", ["package": package.path, "compact": true])

        #expect(map == .reply(.result(text: "10 t1:97010\n", isError: false)))
        guard case .reply(.result(let text, false)) = info else {
            Issue.record("session_info: \(info)")
            return
        }
        #expect(text.contains(#""takeSync":[{"offset":97000,"state":"inSync","take":1}]"#), "\(text)")
        await studio.settle()
    }

    /// C2: the open succeeds with an anchor that does not read; the live calls show the fault.
    @Test func anAnchorFaultReachesTheLiveCalls() async throws {
        let package = try Self.takePackage()
        let anchor = package.url.appending(path: "Capture/take1.anchor")
        chmod(anchor.path, 0o000)
        defer { chmod(anchor.path, 0o644) }
        let studio = try await package.open()
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }

        let map = await send(folder.socket, "take_map", ["package": package.path, "frames": [10]])
        let info = await send(folder.socket, "session_info", ["package": package.path])

        let text = "Cannot read the take anchor file Capture/take1.anchor (errno 13), so the take time is not known."
        #expect(map == .reply(.result(text: text, isError: true)))
        guard case .reply(.result(let json, false)) = info else {
            Issue.record("session_info: \(info)")
            return
        }
        #expect(json.contains(#""takeSyncFaults":[{"errno":13,"file":"Capture/take1.anchor"}]"#), "\(json)")
        await studio.settle()
    }
}
