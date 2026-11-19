import AVFoundation
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio
@testable import DirigibleMCP

/// The tool `clip_sync` (decisions 0049 and 0076, C12). Clip `C` (file `c`, noise) is on `t1`; clip `R`
/// (file `r`, other noise) is on `t2` and holds a part of the audio of `C` at half gain.
@MainActor
struct SyncToolTests {
    static let rate = 48_000

    /// Seeded noise of `seconds`, uniform in -`amplitude`...`amplitude`.
    static func noise(seed: UInt64, seconds: Int, amplitude: Float) -> [Float] {
        var (state, samples) = (seed, [Float]())
        samples.reserveCapacity(seconds * rate)
        for _ in 0..<seconds * rate {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let unit = Double(state >> 11) / Double(1 << 53) * 2 - 1
            samples.append(Float(unit) * amplitude)
        }
        return samples
    }

    static func write(_ samples: [Float], _ file: String, in package: LivePackage) throws {
        let clips = package.url.appending(path: "Clips")
        try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
        try AVAudioFile(forWriting: clips.appending(path: "\(file).wav"), settings: format.settings)
            .write(from: buffer)
    }

    /// Clip `C` of `clip` s at `start` s, and a reference of `reference` s that holds the seconds `copy` of
    /// the clip at `at` s. With `take`, the clip is the audio of take 1, so it has a take sync state.
    static func package(
        clip seconds: Int, start: Int, reference: Int, copy: Range<Int>, at: Int, take: Bool = false
    ) throws -> LivePackage {
        let package = try LivePackage()
        let file = take ? "take1-1-1" : "c"
        var session = try Session(contentsOf: package.url)
        if take {
            try session.addCapture(
                Capture(
                    id: "take1-1-1", deviceUID: "usb-1", deviceName: "USB Mic", hostTimeNanos: takeStart,
                    sampleTime: 0, nominalSampleRate: 48_000, measuredSampleRate: 48_000, latency: 0,
                    resampledFromRate: nil, driftCorrected: true))
        }
        for (id, name, track, from, seconds) in [
            ("r", "r", "t2", 0, reference), (take ? "take1-1-1" : "c", file, "t1", start, seconds),
        ] {
            let length = Frames(seconds * rate)
            try session.addFile(
                AudioFile(
                    id: FileID(id), path: "\(name).wav", layout: .mono, length: length,
                    capture: take && id == file ? "take1-1-1" : nil))
            try session.place(
                Clip(
                    id: id == "r" ? "R" : "C", file: FileID(id), start: Frames(from * rate), offset: 0, length: length),
                on: TrackID(track))
        }
        try session.write(to: package.url)
        if take {
            try FileManager.default.createDirectory(
                at: package.url.appending(path: "Capture"), withIntermediateDirectories: true)
            try TakeAnchor.write(
                Recording(
                    take: 1, playheadFrame: Frames(start * rate), takeStartHostTimeNanos: takeStart,
                    armedTracks: ["t1"]), in: package.url)
        }
        let clip = noise(seed: 1, seconds: seconds, amplitude: 0.3)
        var other = noise(seed: 2, seconds: reference, amplitude: 0.1)
        for index in copy.lowerBound * rate..<copy.upperBound * rate {
            other[at * rate + index - copy.lowerBound * rate] += 0.5 * clip[index]
        }
        try write(clip, file, in: package)
        try write(other, "r", in: package)
        return package
    }

    /// The reply of `clip_sync` of `C` to `t2` on the files, off the main actor.
    func closed(_ package: LivePackage, within: Int? = nil) async -> (text: String, isError: Bool) {
        let tool = Tool.all.first { $0.name == "clip_sync" }
        let path = package.path
        return await onThread {
            var json: [String: Any] = ["package": path, "clip": "C", "to": "t2"]
            json["within"] = within
            let control = CallControl(token: nil, interval: .zero, send: { _ in }, poll: { _ in false }, step: {})
            return tool?.call(json, control: control) ?? ("no tool clip_sync", true)
        }
    }

    /// `text` with the match score, which has two decimals, as `#`.
    static func unscored(_ text: String) -> String { text.replacing(/match \d\.\d\d/, with: "match #") }

    /// The closed package: 1 of the 3 excerpts matches, so the text says that the drift was not
    /// measured, and the clip moves and saves.
    @Test func aClosedPackageSyncs() async throws {
        let package = try Self.package(clip: 90, start: 30, reference: 150, copy: 0..<30, at: 10)

        let answer = await closed(package)

        let text =
            "moved C by -20.000 s (-960000 frames), match #\nthe drift was not measured: only one part of the clip matched"
        #expect(!answer.isError && Self.unscored(answer.text) == text, "\(answer)")
        #expect(try Session(contentsOf: package.url).clip("C")?.clip.start == 480_000)
    }

    @Test func aBadWithinGivesItsText() async throws {
        let package = try LivePackage()

        let answer = await closed(package, within: 0)

        #expect(answer == ("within is a whole number of seconds, 1 or more.", true), "\(answer)")
    }

    /// A clip of take audio that moves ends its text with the take sync line of decision 0061.
    @Test func aTakeClipGivesTheTakeSyncLine() async throws {
        let package = try Self.package(clip: 20, start: 20, reference: 60, copy: 0..<20, at: 10, take: true)

        let answer = await closed(package)

        let note = "Take sync: take 1 offset 20.000 s -> 10.000 s (-10.000 s, -480000 frames)"
        #expect(!answer.isError && answer.text.hasSuffix("\n" + note), "\(answer)")
    }

    /// A clip whose new start is under frame 0 loses its head: the open and the closed path give
    /// the same text, the `cut` line included.
    @Test func aHeadCutGivesTheSameLineOpenAndClosed() async throws {
        let files = try Self.package(clip: 60, start: 30, reference: 60, copy: 20..<60, at: 0)
        let app = try Self.package(clip: 60, start: 30, reference: 60, copy: 20..<60, at: 0)
        let studio = try await app.open()
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }

        let closedAnswer = await closed(files)
        let openAnswer = await send(folder.socket, "clip_sync", ["package": app.path, "clip": "C", "to": "t2"])

        let text = "moved C by -50.000 s (-2400000 frames), match #\ncut 20.000 s at the head"
        #expect(!closedAnswer.isError && Self.unscored(closedAnswer.text) == text, "\(closedAnswer)")
        #expect(openAnswer == .reply(.result(text: closedAnswer.text, isError: false)), "\(openAnswer)")
        #expect(studio.session.clip("C")?.clip.start == 0 && studio.session.clip("C")?.clip.offset == 960_000)
        await studio.settle()
    }

    /// The bridge gets progress that grows, the studio shows the sync while the read holds, and the
    /// sync is one undo step with the agent name.
    @Test func anOpenSessionSyncsAsALongJob() async throws {
        let package = try Self.package(clip: 20, start: 20, reference: 60, copy: 0..<20, at: 10)
        let studio = try await package.open()
        let hold = ChunkHold(at: 5)
        defer { hold.release() }
        studio.environment.loudnessBlock = { hold.step() }
        let (server, folder) = try liveServer(studio)
        defer { server.stop() }
        let (sent, socket, path) = (Sent(), folder.socket, package.path)
        let call = Task {
            await onThread {
                let control = CallControl(token: 1, interval: .zero, send: sent.send, poll: { _ in false }, step: {})
                return AgentBridge(socket: socket, timeout: .seconds(120)).call(
                    tool: "clip_sync", arguments: ["package": path, "clip": "C", "to": "t2"], client: testClient,
                    control: control)
            }
        }
        await until("the sync does not hold") { hold.isHeld }
        #expect(studio.transport == .syncing, "\(studio.transport)")
        hold.release()
        let outcome = await call.value

        guard case .reply(.result(let text, false)) = outcome else {
            Issue.record("\(outcome)")
            return
        }
        let expected =
            "moved C by -10.000 s (-480000 frames), match #\nthe drift was not measured: the clip is shorter than 60 s"
        #expect(Self.unscored(text) == expected, "\(text)")
        let values = sent.progress(token: 1)
        #expect(!values.isEmpty && zip(values, values.dropFirst()).allSatisfy { $0 < $1 }, "\(values)")
        #expect(studio.session.clip("C")?.clip.start == 480_000 && studio.undoAgent?.name == "Test Agent")
        try studio.undo()
        #expect(studio.session.clip("C")?.clip.start == 960_000 && !studio.canUndo, "one undo step")
        await studio.settle()
    }

    /// The lines of a result: the spread line shows over 20 ms and not at 20 ms, and a drift that was
    /// not measured gives its cause; a positive lag has its sign, and a head cut ends the text.
    @Test func theLinesFollowTheDriftAndTheCut() {
        func lines(lag: Int, drift: SyncDrift, cut: Int = 0) -> [String] {
            let result = SyncResult(lag: Frames(lag), score: MatchScore(peak: 0.984, ratio: 9), drift: drift)
            return SyncWork.Moved(clip: "C", result: result, headCut: Frames(cut), sampleRate: 48_000).lines
        }
        let first = "moved C by +1.234 s (59232 frames), match 0.98"
        #expect(lines(lag: 59_232, drift: .spread(960)) == [first])
        #expect(lines(lag: 59_232, drift: .spread(961)) == [first, "the lag changes by 20 ms across the clip"])
        #expect(lines(lag: 59_232, drift: .spread(2_208)) == [first, "the lag changes by 46 ms across the clip"])
        #expect(
            lines(lag: 59_232, drift: .clipTooShort) == [
                first, "the drift was not measured: the clip is shorter than 60 s",
            ])
        #expect(
            lines(lag: -1, drift: .onePartMatched, cut: 288_000) == [
                "moved C by -0.000 s (-1 frames), match 0.98",
                "the drift was not measured: only one part of the clip matched", "cut 6.000 s at the head",
            ])
    }

    /// The JSON has the lag in frames and seconds, the spread and the head cut in frames, and null for
    /// a spread that was not measured, for each cause.
    @Test func theJsonKeepsANilSpreadAsNull() {
        let score = MatchScore(peak: 0.984, ratio: 9)
        let measured = SyncResult(lag: 59_232, score: score, drift: .spread(2_208))
        let unknown = SyncResult(lag: -240_000, score: score, drift: .onePartMatched)
        let short = SyncResult(lag: -240_000, score: score, drift: .clipTooShort)

        #expect(
            SyncWork.Moved(clip: "C", result: measured, headCut: 0, sampleRate: 48_000).json
                == #"{"clip":"C","frames":59232,"headCut":0,"match":0.98,"seconds":1.234,"spread":2208}"#)
        #expect(
            SyncWork.Moved(clip: "C", result: unknown, headCut: 288_000, sampleRate: 48_000).json
                == #"{"clip":"C","frames":-240000,"headCut":288000,"match":0.98,"seconds":-5,"spread":null}"#)
        #expect(
            SyncWork.Moved(clip: "C", result: short, headCut: 0, sampleRate: 48_000).json
                == #"{"clip":"C","frames":-240000,"headCut":0,"match":0.98,"seconds":-5,"spread":null}"#)
    }

    /// The tool description and the skill line say what the tool does and its one-lag limit, and quote
    /// no result line: `dirigible help clip sync` holds those.
    @Test func theAgentTextsQuoteNoResultLine() throws {
        let tool = try #require(Tool.all.first { $0.name == "clip_sync" })
        for (name, text) in [("description", tool.description), ("syncLine", AgentManual.syncLine)] {
            let quoted = ["moved <clip>", "the lag changes by", "the drift was not measured", "at the head"].filter {
                text.contains($0)
            }
            #expect(quoted.isEmpty, "the \(name) quotes \(quoted)")
            #expect(text.contains("one lag") && text.contains("does not correct a drift"), "\(name): \(text)")
        }
        #expect(tool.description.contains("dirigible help clip sync"), "\(tool.description)")
    }

    /// The skill names the tool, each of its arguments, and its command; the manual has no room for the line.
    @Test func theSkillNamesTheSyncTool() throws {
        let tool = try #require(Tool.all.first { $0.name == "clip_sync" })
        let missing = tool.params.map(\.key).filter { !AgentManual.syncLine.contains("`\($0)`") }
        #expect(missing.isEmpty, "the sync line does not name \(missing)")
        #expect(AgentManual.skill.contains(AgentManual.syncLine))
        #expect(AgentManual.skill.contains("| clip_sync | dirigible clip sync |"))
        #expect(!AgentManual.manual(pathLine: "x").contains(AgentManual.syncLine))
    }
}
