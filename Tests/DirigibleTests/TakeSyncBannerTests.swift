import AppKit
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio
@testable import DirigibleMCP

/// The sync banner of a take (decision 0061, C13): one row when a revision with an agent moves a
/// take from in sync to broken, with Undo and Show.
@Suite(.serialized) @MainActor struct TakeSyncBannerTests {
    let folder: TemporaryFolder
    let socket = shortSocket()
    let app: AppDelegate
    let hal = CountingHAL()
    static let agent = AgentName(title: "Test Agent", clientName: nil)
    static let takeStart: UInt64 = 1_000_000_000_000
    static let second = 48_000

    init() throws {
        folder = try TemporaryFolder()
        app = AppDelegate(recordings: nil, agentSocket: socket)
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    /// A take of the tracks of `files` (track ID, clip start in s, clip length in s), recorded at
    /// `playhead` s with latency 0 and the first frame at the take start: file frame 0 is take
    /// frame 0, so a clip at its record place has the shift `playhead`.
    struct Take {
        let number: Int
        let playhead: Int
        let clips: [(track: TrackID, start: Int, offset: Int, length: Int)]
    }

    /// Tracks t1 and t2 on channels 1 and 2 of `duo`, with the clips of `takes`, the capture of each
    /// take file, and the anchor of each take from the real writer. The audio files are missing:
    /// the map reads no audio.
    func package(_ takes: [Take], name: String = "sync") throws -> URL {
        let url = folder.url.appending(path: "\(name).dirigible")
        try Session.create(at: url, sampleRate: 48_000)
        var session = Session(sampleRate: 48_000)
        for (n, channel) in [(1, 1), (2, 2)] {
            let track = TrackID("t\(n)")
            try session.addTrack(track, name: "T\(n)", layout: .mono)
            try session.setRoute(Route.device(uid: "duo", channels: .mono(channel)), track: track)
        }
        try FileManager.default.createDirectory(at: url.appending(path: "Capture"), withIntermediateDirectories: true)
        for take in takes {
            for (index, clip) in take.clips.enumerated() {
                let arm = clip.track == "t1" ? 1 : 2
                let id = "take\(take.number)-\(arm)-1"
                if session.files[FileID(id)] == nil {
                    try session.addCapture(
                        Capture(
                            id: CaptureID(id), deviceUID: "duo", deviceName: "Duo", hostTimeNanos: Self.takeStart,
                            sampleTime: 0, nominalSampleRate: 48_000, measuredSampleRate: 48_000, latency: 0,
                            resampledFromRate: nil, driftCorrected: true))
                    try session.addFile(
                        AudioFile(
                            id: FileID(id), path: "\(id).wav", layout: .mono, length: Frames(600 * Self.second),
                            capture: CaptureID(id)))
                }
                try session.place(
                    Clip(
                        id: ClipID("\(id)-c\(index)"), file: FileID(id), start: Frames(clip.start * Self.second),
                        offset: Frames(clip.offset * Self.second), length: Frames(clip.length * Self.second)),
                    on: clip.track)
            }
            try TakeAnchor.write(
                Recording(
                    take: take.number, playheadFrame: Frames(take.playhead * Self.second),
                    takeStartHostTimeNanos: Self.takeStart, armedTracks: ["t1", "t2"]),
                in: url)
        }
        try session.write(to: url)
        return url
    }

    /// Take 1 on both tracks from 0 for 60 s: in sync at 0.
    func oneTake() throws -> URL {
        try package([Take(number: 1, playhead: 0, clips: [("t1", 0, 0, 60), ("t2", 0, 0, 60)])])
    }

    func open(_ url: URL) async throws -> (SessionWindow, Studio) {
        let model = await app.open(url)
        let studio = try #require(await model.opened() ? model.studio : nil)
        return (model, studio)
    }

    /// The sync rows of the chrome of `model` now: the same value that the chrome loop writes.
    func rows(_ model: SessionWindow) -> [WindowBanner] {
        ChromeState(model: model).shown.banners.filter { $0.key.hasPrefix("takeSyncBroken") }
    }

    func cut(_ studio: Studio, _ range: Range<Int>, on tracks: [TrackID] = ["t1"], agent: AgentName? = agent)
        throws
    {
        let frames = Frames(range.lowerBound * Self.second)..<Frames(range.upperBound * Self.second)
        try studio.edit(ripple: true, agent: agent) { s throws(SessionError) in try s.rippleDelete([frames], on: tracks)
        }
    }

    /// A call from an agent named "Test Agent", off the main actor, so the server can answer.
    func call(_ tool: String, _ arguments: [String: any Sendable]) async -> AgentBridge.Outcome {
        let socket = socket
        return await withCheckedContinuation { done in
            Thread.detachNewThread {
                let bridge = AgentBridge(socket: socket, timeout: .seconds(120))
                done.resume(
                    returning: bridge.call(
                        tool: tool, arguments: arguments, client: ClientInfo(title: "Test Agent", name: "test")))
            }
        }
    }

    static let english = Result { try stringsTable("en") }

    func englishText(_ key: L10n) -> String { (try? Self.english.get())?[key.rawValue] ?? key.rawValue }

    /// The first state: a ripple delete of 1 s at 10 s on t1 only, from the app server, breaks
    /// take 1 from 0:00:10. The chrome loop shows one row with the agent name, and the text names
    /// the take and the break time.
    @Test func anAgentCutFromInSyncShowsOneRow() async throws {
        let url = try oneTake()
        let (model, _) = try await open(url)
        app.agents.start()
        defer { app.agents.stop() }

        let outcome = await call(
            "clip_ripple_delete", ["package": url.path, "from": [480_000], "to": [528_000], "track": ["t1"]])

        guard case .reply(.result(let text, false)) = outcome else {
            Issue.record("clip_ripple_delete: \(outcome)")
            return
        }
        #expect(text.contains("Take sync: take 1 in sync"), "\(text)")
        let row = WindowBanner.takeSyncBroken(take: 1, from: 480_000, rate: 48_000, agent: "Test Agent")
        await until(limit: .seconds(10), "the chrome loop shows the row") { model.shown.banners.contains(row) }
        #expect(model.shown.banners.filter { $0.key.hasPrefix("takeSyncBroken") } == [row])
        #expect(row.kind == .warning && row.announcement == .medium)
        #expect(
            takeSyncBreakText(take: 1, from: 480_000, rate: 48_000, agent: "Test Agent", text: englishText)
                == "Test Agent moved part of the take audio. Take 1 is out of sync with the recording from 0:00:10.")
        #expect(
            takeSyncBreakText(take: 1, from: 480_000, rate: 48_000, agent: nil, text: englishText)
                == "An AI agent moved part of the take audio. Take 1 is out of sync with the recording from 0:00:10.")
        await model.close()
    }

    /// A user cut shows no row; the inspector line shows the break (the control of "any edit").
    @Test func aUserCutShowsNoRow() async throws {
        let (model, studio) = try await open(try oneTake())

        try cut(studio, 10..<11, agent: nil)

        #expect(studio.takeSyncChange.revision == studio.sessionRevision)
        #expect(studio.takeMap.map.sync[1] == .broken(from: 480_000, shifts: 2))
        #expect(rows(model) == [])
        await model.close()
    }

    /// Undo of the row (one Edit > Undo) removes the agent edit and the row; Redo of the agent
    /// entry shows the row again; Show moves the playhead to the break.
    @Test func undoRedoAndShowOfAnAgentBreak() async throws {
        let (model, studio) = try await open(try oneTake())
        try cut(studio, 10..<11)
        let row = WindowBanner.takeSyncBroken(take: 1, from: 480_000, rate: 48_000, agent: "Test Agent")
        #expect(rows(model) == [row])

        model.transport(.seek(.frame(480_000)))
        await until(limit: .seconds(10), "Show moves the playhead to the break") { studio.playhead == 480_000 }

        model.undo()
        #expect(studio.takeMap.map.sync[1] == .inSync(offset: 0))
        #expect(rows(model) == [], "the undo revision has no agent")

        model.redo()
        #expect(studio.takeMap.map.sync[1] == .broken(from: 480_000, shifts: 2))
        #expect(rows(model) == [row], "the redo names the agent of the entry")
        await model.close()
    }

    /// Redo of a user edit that breaks the take shows no row.
    @Test func aRedoOfAUserBreakShowsNoRow() async throws {
        let (model, studio) = try await open(try oneTake())
        try cut(studio, 10..<11, agent: nil)
        model.undo()
        model.redo()
        #expect(studio.takeMap.map.sync[1] == .broken(from: 480_000, shifts: 2))
        #expect(studio.takeSyncChange.changes.count == 1, "the redo makes the break again")
        #expect(rows(model) == [])
        await model.close()
    }

    /// An agent break, a user repair, then a user Undo of the repair: the undo passes no agent.
    @Test func aUserUndoOfARepairShowsNoRow() async throws {
        let (model, studio) = try await open(try oneTake())
        try cut(studio, 10..<11)
        #expect(rows(model).count == 1)
        try studio.edit(ripple: true) { s throws(SessionError) in
            try s.rippleInsert(Frames(Self.second), at: 480_000, on: ["t1"])
        }
        // The insert leaves a gap at the cut, so the moved clip has its old shift again.
        #expect(studio.takeMap.map.sync[1] == .inSync(offset: 0))
        #expect(rows(model) == [])

        model.undo()

        #expect(studio.takeMap.map.sync[1] == .broken(from: 480_000, shifts: 2))
        #expect(rows(model) == [])
        await model.close()
    }

    /// A second cut from broken shows no new row (the control of a whole-state compare).
    @Test func aSecondCutFromBrokenShowsNoNewRow() async throws {
        let (model, studio) = try await open(try oneTake())
        try cut(studio, 10..<11)
        #expect(rows(model).count == 1)

        try cut(studio, 20..<21)

        #expect(studio.takeSyncChange.revision == studio.sessionRevision)
        #expect(studio.takeMap.map.sync[1] == .broken(from: 480_000, shifts: 3))
        #expect(rows(model) == [])
        await model.close()
    }

    /// An agent edit with no take audio, and an agent head trim that keeps one shift, show no row.
    @Test func noTakeAudioAndAHeadTrimShowNoRow() async throws {
        let (plain, plainStudio) = try await open(
            try await timelinePackage(in: folder.url, tracks: 2, seconds: 60))
        try cut(plainStudio, 10..<11)
        #expect(plainStudio.takeSyncChange.revision == plainStudio.sessionRevision)
        #expect(plainStudio.takeMap.map.sync.isEmpty)
        #expect(rows(plain) == [])
        await plain.close()

        let (model, studio) = try await open(try oneTake())
        try cut(studio, 0..<1, on: ["t1", "t2"])
        #expect(studio.takeSyncChange.changes.map(\.new) == [.inSync(offset: -48_000)], "the change reached")
        #expect(rows(model) == [])
        await model.close()
    }

    /// Two takes: an agent cut in take 2 shows one row, and it names take 2.
    @Test func twoTakesWhereTheEditBreaksTake2() async throws {
        let url = try package([
            Take(number: 1, playhead: 0, clips: [("t1", 0, 0, 60), ("t2", 0, 0, 60)]),
            Take(number: 2, playhead: 120, clips: [("t1", 120, 0, 60), ("t2", 120, 0, 60)]),
        ])
        let (model, studio) = try await open(url)

        try cut(studio, 130..<131)

        #expect(studio.takeMap.map.sync[1] == .inSync(offset: 0))
        #expect(
            rows(model) == [
                .takeSyncBroken(take: 2, from: Frames(130 * Self.second), rate: 48_000, agent: "Test Agent")
            ]
        )
        await model.close()
    }

    /// A live agent import over the audio that a cold open copies breaks the take: the copy at
    /// 70 s is a copy only while t1 plays take seconds 0 to 1 in sync, and the import overwrites
    /// them.
    @Test func aLiveAgentImportThatBreaksATakeShowsARow() async throws {
        let url = try package([
            Take(number: 1, playhead: 0, clips: [("t1", 0, 0, 60), ("t2", 0, 0, 60), ("t1", 70, 0, 1)])
        ])
        let source = folder.url.appending(path: "silence.wav")
        try writeSilentWAV(source, channels: 1)
        let (model, studio) = try await open(url)
        #expect(studio.takeMap.map.sync[1] == .inSync(offset: 0), "the cold open is a copy")

        _ = try await studio.importAudio(
            source, to: ImportTarget(track: "t1", start: 0), level: false, agent: Self.agent, progress: { _ in })

        #expect(studio.takeMap.map.sync[1] == .broken(from: Frames(70 * Self.second), shifts: 2))
        #expect(
            rows(model) == [.takeSyncBroken(take: 1, from: Frames(70 * Self.second), rate: 48_000, agent: "Test Agent")]
        )
        await model.close()
    }

    /// A take completion after an edit shows no row; then an agent cut in take 2, recorded in the
    /// window, shows one row that names take 2: its anchor came with the take outcome.
    @Test func aTakeRecordedInTheWindowThenAnAgentBreak() async throws {
        let (model, studio) = try await open(try oneTake())
        studio.environment = hal.environment
        try cut(studio, 0..<1, on: ["t1", "t2"], agent: nil)
        await studio.perform(.seek(.frame(studio.session.end)))
        model.armed = ["t1"]

        await model.record()
        #expect(studio.transport == .recording(take: 2))
        await hal.feed(seconds: 3)
        await model.stop()
        await until(limit: .seconds(30), "the take ends") { studio.transport == .idle && studio.lastTake != nil }

        let take2 = studio.takeMap.map.sync[2]
        #expect(take2 != nil, "take 2 has take time: \(studio.takeMap.map.sync)")
        #expect(studio.takeSyncChange.changes == [], "a take completion is no transition")
        #expect(rows(model) == [])

        let clip = try #require(studio.session.track("t1")?.clips.last)
        // The counting HAL feeds a short take: the insert goes in the middle of its clip.
        let inside = clip.start + Frames(clip.length.count / 2)
        try studio.edit(ripple: true, agent: Self.agent) { s throws(SessionError) in
            try s.rippleInsert(Frames(Self.second), at: inside, on: ["t1"])
        }

        #expect(
            rows(model) == [
                .takeSyncBroken(take: 2, from: inside + Frames(Self.second), rate: 48_000, agent: "Test Agent")
            ])
        await model.close()
    }
}
