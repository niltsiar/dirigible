import Foundation
import Testing

@testable import DirigibleAudio
@testable import DirigibleCore

/// What a scripted engine part saw: its calls, its QoS, and the sample count of piece 0.
final class EngineRecord: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [(qos: qos_class_t, samples: Int)] = []

    func add(qos: qos_class_t, samples: Int) { lock.withLock { seen.append((qos, samples)) } }
    var calls: Int { lock.withLock { seen.count } }
    var qos: [qos_class_t] { lock.withLock { seen.map(\.qos) } }
    var samples: [Int] { lock.withLock { seen.map(\.samples) } }
}

/// `Studio.transcribe` (decision 0065 D5): the words anchor to the files, so edits during the job
/// keep their place (C8); one undo entry (C9).
@MainActor
struct StudioTranscribeTests {
    /// "uno" at 0.5 s, "dos" at 5.0 s, and "tres" at 8.0 s of piece time, in ticks of 10 ms.
    static let words = [
        TimedWord(text: "uno", start: 50, end: 100), TimedWord(text: "dos", start: 500, end: 550),
        TimedWord(text: "tres", start: 800, end: 860),
    ]

    /// A scripted engine part: it reads piece 0, records the call, holds on `gate`, and gives
    /// `words` as piece 0, or nil when the stop flag is set.
    static func engine(_ words: [TimedWord] = words, gate: Gate? = nil, record: EngineRecord = EngineRecord())
        -> TranscribeEngine
    {
        { _, _, count, _, read, stop, _ throws(TranscribeError) in
            record.add(qos: qos_class_self(), samples: try read(0).count)
            gate?.waitOnce()
            if stop.isSet { return nil }
            return Transcription(pieces: [words] + Array(repeating: [], count: max(0, count - 1)), language: "es")
        }
    }

    /// A studio on `package` with the test environment, the engine part `engine`, a reason text of
    /// its own, and a model folder in the package folder. With `model`, the folder has the base
    /// file, and the model check passes with no catalog file.
    static func open(
        _ package: MixPackage, hal: TestHAL = TestHAL([]), engine: @escaping TranscribeEngine = engine(),
        model: Bool = true, load: @escaping WhisperModelStore.Loader = { _ in AsyncThrowingStream { $0.finish() } }
    ) async throws -> Studio {
        let studio = try await Studio.open(package.url)
        studio.environment = .test(hal)
        studio.environment.transcribe = engine
        studio.environment.transcribeReason = UUID().uuidString
        let folder = package.folder.url.appending(path: "Models")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if model {
            FileManager.default.createFile(
                atPath: folder.appending(path: WhisperModel.base.fileName).path, contents: Data([1]))
        }
        studio.environment.modelStore = WhisperModelStore(folder: folder, load: load)
        studio.environment.checkModel = { model, folder in
            CheckedModel(model: model, url: folder.appending(path: model.fileName))
        }
        return studio
    }

    /// Runs one job on `track` and gives its result.
    static func job(_ studio: Studio, track: TrackID = "t1", agent: AgentName? = nil)
        -> Task<Result<TranscribeReport, StudioError>, Never>
    {
        Task {
            do throws(StudioError) {
                return .success(
                    try await studio.transcribe(track: track, language: .code("es"), model: .base, agent: agent))
            } catch {
                return .failure(error)
            }
        }
    }

    /// A ripple delete of `range` on `t1` through `Studio.edit`.
    static func cut(_ studio: Studio, _ range: Range<Frames>) throws {
        let delete = { (session: inout Session) throws(StudioError) in
            do throws(SessionError) { try session.rippleDelete(range, on: ["t1"]) } catch { throw .session(error) }
        }
        try studio.edit(agent: nil, refused: { $0 }, delete)
    }

    static func xml(_ package: MixPackage) -> Data? {
        FileManager.default.contents(atPath: package.url.appending(path: "session.xml").path)
    }

    /// C8 a: a ripple delete during the job stays, and after the job "dos" shows at its file place
    /// in the moved clip: 1 s earlier. An import in timeline time gives the old start.
    @Test func anEditDuringTheJobKeepsItsPlace() async throws {
        let fixture = try await ExportStudioFixture.make()
        let (gate, record) = (Gate(limit: Gate.openLimit), EngineRecord())
        let studio = try await Self.open(fixture.package, engine: Self.engine(gate: gate, record: record))
        let job = Self.job(studio)
        await gate.entered()

        try Self.cut(studio, 96_000..<144_000)
        gate.open()

        let report = try await job.value.get()
        #expect(report.kept == 3 && report.language == "es")
        let words = studio.session.words(on: ["t1"])
        #expect(words.map(\.text) == ["uno", "dos", "tres"])
        #expect(words.first { $0.text == "dos" }?.range.lowerBound == 192_000, "5.0 s - 1 s")
        #expect(studio.session.track("t1")?.clips.count == 2, "the cut stays")
        let samples = try #require(record.samples.first)
        #expect(abs(samples - 160_000) <= 32, "piece 0 is the 10 s span at 16 kHz")
        await studio.settle()
    }

    /// The 5 s of clip c1 of the split fixture: "uno" at 0.5 s, "dos" at 2.0 s, "tres" at 4.0 s.
    static let splitWords = [
        TimedWord(text: "uno", start: 50, end: 100), TimedWord(text: "dos", start: 200, end: 250),
        TimedWord(text: "tres", start: 400, end: 450),
    ]

    /// Checks the D11 view (decision 0057) after a render of c1 during the job: the words anchor to
    /// f1 in f1 frames, the rendered file holds none, and the words show under c1 at 20.5, 22, 24 s.
    static func expectTheWordsOnTheRoot(_ studio: Studio, _ id: TranscriptID?) throws {
        let id = try #require(id)
        let words = try #require(studio.session.transcripts[id]?.words)
        #expect(Array(words.keys) == ["f1"], "no anchor on the rendered file")
        #expect(words["f1"]?.all.map(\.number) == [1, 2, 3])
        #expect(words["f1"]?.all.first?.range.lowerBound == 984_000, "20.5 s of f1")
        #expect(studio.session.clip("c1")?.clip.file != "f1", "c1 is on the rendered file")
        let shown = studio.session.words(on: ["t1"])
        #expect(shown.map(\.range.lowerBound) == [984_000, 1_056_000, 1_152_000])
    }

    /// C8 b: a render of c1 commits during the job; the words go to the root (0057 D11).
    @Test func aRenderDuringTheJobKeepsTheWordsOnTheRoot() async throws {
        let fixture = try await StudioSplitTests.make()
        let gate = Gate(limit: Gate.openLimit)
        let studio = try await Self.open(fixture.package, engine: Self.engine(Self.splitWords, gate: gate))
        let job = Self.job(studio)
        await gate.entered()

        _ = try await studio.renderClips(["c1"], request: StudioRenderTests().noise) { _ in }
        gate.open()

        try Self.expectTheWordsOnTheRoot(studio, try await job.value.get().id)
        await studio.settle()
    }

    /// C8 c: a split stereo commits during the job; the words show on both mono tracks. An undo of
    /// the split before the job end leaves the words on the source file only.
    @Test(arguments: [false, true]) func aSplitDuringTheJobGivesTheWordsToBothMonoTracks(undo: Bool) async throws {
        let fixture = try await StudioSplitTests.make()
        let gate = Gate(limit: Gate.openLimit)
        let studio = try await Self.open(fixture.package, engine: Self.engine(Self.splitWords, gate: gate))
        let job = Self.job(studio)
        await gate.entered()

        let part = try #require(try await studio.splitStereo(["c1"], names: ("L", "R")) { _ in }.first)
        if undo { try studio.undo() }
        gate.open()

        let id = try #require(try await job.value.get().id)
        let files = Set(try #require(studio.session.transcripts[id]?.words).keys)
        if undo {
            #expect(files == ["f1"])
        } else {
            #expect(files.count == 3, "f1 and the two mono files")
            for track in [part.leftTrack, part.rightTrack] {
                let shown = studio.session.words(on: [track])
                #expect(shown.map(\.text) == ["uno", "dos", "tres"])
                #expect(shown.map(\.range.lowerBound) == [984_000, 1_056_000, 1_152_000])
            }
        }
        await studio.settle()
    }

    /// C8 d: a ripple delete during the end save of the job stays with its own undo entry: the
    /// first undo removes the cut, the second the transcript.
    @Test func anEditDuringTheEndSaveStaysWithItsUndoEntry() async throws {
        let fixture = try await ExportStudioFixture.make()
        let studio = try await Self.open(fixture.package)
        let saving = AsyncGate()
        let save = studio.environment.saveSession
        studio.environment.saveSession = { session, lock throws(SessionFileError) in
            await saving.wait()
            return try await save(session, lock)
        }
        let job = Self.job(studio)
        await saving.entered()

        try Self.cut(studio, 96_000..<144_000)
        saving.open()

        #expect(try await job.value.get().kept == 3)
        #expect(studio.session.track("t1")?.clips.count == 2 && studio.session.words(on: ["t1"]).count == 3)
        try studio.undo()
        #expect(studio.session.track("t1")?.clips.count == 1, "the first undo removes the cut")
        #expect(studio.session.words(on: ["t1"]).count == 3)
        try studio.undo()
        #expect(studio.session.transcripts.isEmpty, "the second undo removes the transcript")
        await studio.settle()
    }

    /// C8 e: the engine returns while a level of this studio holds in its save; the end turn waits,
    /// and the session keeps the gains and the words, with the transcript entry after the level.
    @Test func anEndTurnDuringALevelWaitsAndKeepsBoth() async throws {
        let fixture = try await ExportStudioFixture.make()
        let gate = Gate(limit: Gate.openLimit)
        let studio = try await Self.open(fixture.package, engine: Self.engine(gate: gate))
        let (saving, done) = (AsyncGate(), AsyncGate())
        done.open()
        studio.environment.transcribeWorkDone = { await done.wait() }
        let save = studio.environment.saveSession
        studio.environment.saveSession = { session, lock throws(SessionFileError) in
            await saving.wait()
            return try await save(session, lock)
        }
        let job = Self.job(studio)
        await gate.entered()
        let level = Task { try await studio.level(["c1"], .eachClip) }
        await saving.entered()

        gate.open()
        await done.entered()
        try await Task.sleep(for: .milliseconds(50))
        saving.open()

        _ = try await level.value
        #expect(try await job.value.get().kept == 3)
        let gain = try #require(studio.session.clip("c1")?.clip.gain)
        #expect(gain != .zero, "the level gain stays")
        #expect(studio.session.words(on: ["t1"]).count == 3)
        try studio.undo()
        #expect(studio.session.transcripts.isEmpty && studio.session.clip("c1")?.clip.gain == gain)
        await studio.settle()
    }

    /// C8 f: the engine returns while a render of this studio holds in its write turn; the end turn
    /// waits, the words go to the root (0057 D11), and the transcript entry is after the render.
    @Test func anEndTurnDuringARenderWaitsAndKeepsBoth() async throws {
        let fixture = try await StudioSplitTests.make()
        let gate = Gate(limit: Gate.openLimit)
        let studio = try await Self.open(fixture.package, engine: Self.engine(Self.splitWords, gate: gate))
        let (rendering, done) = (AsyncGate(), AsyncGate())
        done.open()
        studio.environment.transcribeWorkDone = { await done.wait() }
        studio.environment.clipRenderWorkDone = { await rendering.wait() }
        let job = Self.job(studio)
        await gate.entered()
        let noise = StudioRenderTests().noise
        let render = Task { try await studio.renderClips(["c1"], request: noise) { _ in } }
        await rendering.entered()

        gate.open()
        await done.entered()
        try await Task.sleep(for: .milliseconds(50))
        rendering.open()

        _ = try await render.value
        try Self.expectTheWordsOnTheRoot(studio, try await job.value.get().id)
        try studio.undo()
        #expect(studio.session.transcripts.isEmpty && studio.session.clip("c1")?.clip.file != "f1")
        await studio.settle()
    }

    /// C9: the job is one undo entry with the agent; undo removes the transcript, redo returns it,
    /// and the save writes one transcript file.
    @Test func theJobIsOneUndoEntryWithItsAgent() async throws {
        let fixture = try await ExportStudioFixture.make()
        let studio = try await Self.open(fixture.package)
        let agent = AgentName(title: "Test Agent", clientName: nil)

        let id = try #require(try await Self.job(studio, agent: agent).value.get().id)

        #expect(studio.undoAgent == agent)
        let transcripts = fixture.package.url.appending(path: "Transcripts")
        #expect(try FileManager.default.contentsOfDirectory(atPath: transcripts.path).count == 1)
        try studio.undo()
        #expect(studio.session.transcripts.isEmpty && !studio.canUndo)
        try studio.redo()
        #expect(studio.session.transcripts.keys.contains(id))
        await studio.settle()
    }

    /// C9: a job that keeps no word adds no undo entry and no save, and the old words stay.
    @Test func aJobWithNoWordAddsNoUndoEntry() async throws {
        let fixture = try await ExportStudioFixture.make()
        let studio = try await Self.open(fixture.package)
        _ = try await Self.job(studio).value.get()
        let before = (studio.session, studio.sessionRevision, Self.xml(fixture.package))
        studio.environment.transcribe = Self.engine([])

        let report = try await Self.job(studio).value.get()

        #expect(report.id == nil && report.kept == 0)
        #expect(studio.session == before.0 && studio.sessionRevision == before.1)
        #expect(Self.xml(fixture.package) == before.2)
        #expect(studio.session.words(on: ["t1"]).count == 3, "the old words stay")
        await studio.settle()
    }
}
