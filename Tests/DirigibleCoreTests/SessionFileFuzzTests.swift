import Foundation
import Testing

@testable import DirigibleCore

/// C7, C14, C17: seeded mutations of valid session and transcript files (`XMLMutator`). An open
/// gives a session whose save reads back equal, or a `SessionFileError`, in 2 s or less, and
/// changes no file of the case folder. Before each case the test writes
/// `<test> seed <n> case <i> family <f>` to stderr, so a trap in process names its case.
@Suite(.serialized) struct SessionFileFuzzTests {
    /// The seeds of each fuzz test of this target.
    static let seeds: [UInt64] = [20_261_104]

    /// The cases, refusals, and opens of one family.
    struct Tally {
        var cases = 0
        var refused = 0
        var parsed = 0
        var opened = 0
        var expected: [String: Int] = [:]
    }

    /// The newest session file: each feature that raises the file version, through the edits.
    static func newestSession() throws -> Session {
        var session = try SessionFileTests().fullSession()
        let treatment = try #require(
            Treatment([.declip(.standard), .rumble(.standard), .hum(.hz50), .noise(.standard), .deess(.standard)]))
        let origin = RenderOrigin(
            source: "f3", offset: 24_000, treatment: treatment, addedGain: try #require(Gain(dB: 1.5)))
        try session.addFile(AudioFile(id: "f3 NR", path: "f3 NR.wav", layout: .stereo, length: 48_000, origin: origin))
        try session.addFile(AudioFile(id: "fa", path: "a.wav", layout: .mono, length: 10_000))
        try session.addFile(AudioFile(id: "fb", path: "b.wav", layout: .mono, length: 10_000))
        let drift = DriftOrigin(
            source: "fb", offset: 500, ratio: try #require(DriftRatio(1 / (1 + 50e-6))),
            addedGain: try #require(Gain(dB: 1.5)))
        try session.addFile(AudioFile(id: "fb drift", path: "b drift.wav", layout: .mono, length: 9_000, drift: drift))
        try session.addTrack("t3", name: "Guest app", layout: .mono)
        try session.setRoute(.app(bundleID: "us.zoom.xos"), track: "t3")
        try session.place(Clip(id: "A", file: "fa", start: 1_000, offset: 1_000, length: 4_000), on: "t3")
        try session.place(Clip(id: "B", file: "fb", start: 5_000, offset: 1_000, length: 4_000), on: "t3")
        try session.setFades(["B": try #require(Fades(fadeIn: 0, fadeOut: 100))])
        try session.setCrossfades(["A": 960])
        try session.setEnvelope([2_000: try #require(Gain(dB: -3)), 9_000: try #require(Gain(dB: 2))], clip: "c1")
        try session.setRides(["c3": envelope([(1_200, -1.37), (6_000, 2.5)])])
        try session.setMuted(true, tracks: ["t3"])
        try session.setSoloed(true, tracks: ["t1"])
        try session.setRole(.dialogue, tracks: ["t1"])
        try session.setFollowTrack(true, tracks: ["t2"])
        try session.setMatch(["t1": try VoiceMatchTests.match(VoiceMatchTests.curve([0: 6.5, 12: -3.1]))])
        try session.setMarker(
            try MarkerFieldTests.chapter(url: "https://example.com/a?b=1&c=<2>", image: MarkerFieldTests.image))
        session.setEpisode(try EpisodeSessionTests.fullEpisode())
        session.addWords([(1, 0..<4_800, "hello"), (2, 4_800..<9_600, "world")], file: "f1")
        session.addWords([(3, 0..<2_400, "and you")], file: "f2")
        try session.setExportPreset(ExportPresetTests.preset(#"Feed & "Show""#))
        try session.setExportPreset(ExportPresetTests.preset("Archive", ExportPresetTests.wav))
        let bin = try session.addBin("bin1", named: #"Beds & "Stings""#)
        try session.addItem(try session.excerpt(of: ["c3", "B"]), named: "Bed <1>", to: bin, id: "item1")
        #expect(session.fileVersion == sessionVersion, "the corpus has each versioned feature")
        return session
    }

    /// A version 1 session: one file, one track, one clip.
    static func versionOneSession() throws -> Session {
        var session = Session(sampleRate: 44_100)
        try session.addFile(AudioFile(id: "f1", path: "a.wav", layout: .mono, length: 44_100))
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.place(Clip(id: "c1", file: "f1", start: 0, offset: 0, length: 44_100), on: "t1")
        #expect(session.fileVersion == 1)
        return session
    }

    /// A case folder that holds only the package `E.dirigible`.
    let folder = FileManager.default.temporaryDirectory.appending(path: "SessionFileFuzzTests-\(UUID().uuidString)")
    var package: URL { folder.appending(path: "E.dirigible") }

    /// The relative path and the bytes of each item of the case folder (a folder has no bytes).
    func snapshot() throws -> [String: Data] {
        let items = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?.allObjects ?? []
        var result: [String: Data] = [:]
        for case let url as URL in items {
            let path = String(url.path.dropFirst(folder.path.count))
            result[path] = url.hasDirectoryPath ? Data() : try Data(contentsOf: url)
        }
        return result
    }

    /// Writes `data` at `path` of the package, opens the package, and records an issue for an open
    /// over 2 s and for a change in the case folder.
    func open(_ data: Data, at path: String, _ context: String) throws -> Result<Session, SessionFileError> {
        try data.write(to: package.appending(path: path))
        let before = try snapshot()
        var result = Result<Session, SessionFileError>.failure(.malformedXML)
        let elapsed = ContinuousClock().measure {
            result = Result { () throws(SessionFileError) in try Session(contentsOf: package) }
        }
        if elapsed > .seconds(2) { Issue.record("\(context): the open takes \(elapsed)") }
        if try snapshot() != before { Issue.record("\(context): the open changes a file of the case folder") }
        return result
    }

    static func short(_ value: Any) -> String { String(String(describing: value).prefix(300)) }

    static func announce(_ test: String, _ label: String) {
        FileHandle.standardError.write(Data("\(test) \(label)\n".utf8))
    }

    /// Prints the counts of each family and records an issue when less than 10 % of the files pass
    /// the XML parse, and with `eachRefuses` for a family with no refusal.
    static func check(
        _ tally: [MutationFamily: Tally], families: [MutationFamily], eachRefuses: Bool, test: String, seed: UInt64
    ) {
        for family in families {
            let count = tally[family, default: Tally()]
            let kinds = count.expected.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }
            print(
                "\(test) seed \(seed) \(family.rawValue): cases \(count.cases), refused \(count.refused),",
                "parsed \(count.parsed), opened \(count.opened), expected \(kinds.joined(separator: ", "))")
            #expect(!eachRefuses || count.refused > 0, "seed \(seed) \(family.rawValue) refuses no file")
        }
        let cases = tally.values.map(\.cases).reduce(0, +)
        let parsed = tally.values.map(\.parsed).reduce(0, +)
        #expect(parsed * 10 >= cases, "seed \(seed): only \(parsed) of \(cases) files pass the XML parse")
    }

    /// C7, C17: 2,000 session files of the families M1 to M12, the fixed M3 and M12 cases first.
    @Test(arguments: seeds)
    func mutatedSessionsRefuseOrRoundTrip(seed: UInt64) throws {
        let test = "mutatedSessionsRefuseOrRoundTrip"
        var random = SplitMix(seed: seed)
        let corpus = [try Self.newestSession().checkedData(), try Self.versionOneSession().checkedData()]
            .map(XMLMutator.init)
        var fixed: [Mutation] = []
        for (element, attribute) in [
            ("file", "length"), ("clip", "gain"), ("track", "muted"), ("track", "layout"), ("track", "name"),
        ] {
            let value = try #require(corpus[0].attributes.first { $0.element == element && $0.name == attribute }).value
            for stress in XMLMutator.stressValues(for: value) {
                fixed.append(try #require(corpus[0].setting(element, attribute, to: stress)))
            }
        }
        for (index, pool) in XMLMutator.poolPaths.enumerated() {
            fixed.append(try #require(corpus[0].settingPath(pool.path, refused: pool.refused, file: index)))
        }
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        var tally: [MutationFamily: Tally] = [:]
        for index in 0..<2_000 {
            var next = index < fixed.count ? fixed[index] : nil
            while next == nil {
                let family = MutationFamily.allCases.randomElement(using: &random)!
                next = corpus.randomElement(using: &random)!.mutate(family, using: &random)
            }
            let mutation = try #require(next)
            let context = "seed \(seed) case \(index) family \(mutation.family.rawValue): \(mutation.note.prefix(200))"
            Self.announce(test, "seed \(seed) case \(index) family \(mutation.family.rawValue)")
            let result = try open(mutation.data, at: "session.xml", context)
            tally[mutation.family, default: Tally()].add(result, mutation.expected)
            Self.judge(result, mutation.expected, context)
        }
        Self.check(tally, families: MutationFamily.allCases, eachRefuses: true, test: test, seed: seed)
    }

    /// The oracle of a session file: the refusal or the open that `expected` allows, and an open
    /// session whose save reads back equal.
    static func judge(_ result: Result<Session, SessionFileError>, _ expected: Expected, _ context: String) {
        switch result {
        case .failure(let error):
            switch expected {
            case .malformed where error != .malformedXML:
                Issue.record("\(context): refused as \(short(error)), not as malformed XML")
            case .pathRefused(let path) where error != .invalidSession(.invalidPath(path)):
                Issue.record("\(context): refused as \(short(error)), not as an invalid path")
            case .pathKept: Issue.record("\(context): a path inside Clips/ is refused as \(short(error))")
            default: break
            }
        case .success(let session):
            switch expected {
            case .malformed, .refused: Issue.record("\(context): a file with a DTD opens")
            case .pathRefused: Issue.record("\(context): a path outside Clips/ opens")
            case .pathKept(let file, let path) where session.files[FileID(file)]?.path != path:
                Issue.record("\(context): the file \(file) opens with another path")
            default: break
            }
            do throws(SessionFileError) {
                if try Session(xml: try session.checkedData()) != session {
                    Issue.record("\(context): the open session saves, and the save reads back unequal")
                }
            } catch {
                Issue.record("\(context): the open session does not save: \(short(error))")
            }
        }
    }

    /// C7: 500 transcript files of the families M1 to M11. `TranscriptStore.decode` gives words that
    /// encode and decode equal, or a refusal, and the package that names the file still opens.
    @Test(arguments: seeds)
    func mutatedTranscriptFilesRefuseOrRoundTrip(seed: UInt64) throws {
        let test = "mutatedTranscriptFilesRefuseOrRoundTrip"
        var random = SplitMix(seed: seed)
        let session = try Self.newestSession()
        let transcript = try #require(session.transcripts.values.first)
        let words = try #require(transcript.words)
        #expect(words.count == 2, "two <words> elements")
        let mutator = XMLMutator(TranscriptStore.encode(words))
        let families = MutationFamily.allCases.filter { $0 != .poolPath }
        try FileManager.default.createDirectory(
            at: package.appending(path: transcriptsFolderName), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try session.checkedData().write(to: package.appending(path: "session.xml"))

        var tally: [MutationFamily: Tally] = [:]
        for index in 0..<500 {
            var next: Mutation?
            while next == nil { next = mutator.mutate(families.randomElement(using: &random)!, using: &random) }
            let mutation = try #require(next)
            let context = "seed \(seed) case \(index) family \(mutation.family.rawValue): \(mutation.note.prefix(200))"
            Self.announce(test, "seed \(seed) case \(index) family \(mutation.family.rawValue)")
            var decoded = Result<[FileID: Anchors], SessionFileError>.failure(.malformedXML)
            let elapsed = ContinuousClock().measure {
                decoded = Result { () throws(SessionFileError) in try TranscriptStore.decode(mutation.data) }
            }
            if elapsed > .seconds(2) { Issue.record("\(context): the decode takes \(elapsed)") }
            tally[mutation.family, default: Tally()].add(decoded, mutation.expected)
            switch decoded {
            case .failure(let error):
                if mutation.expected == .malformed, error != .malformedXML {
                    Issue.record("\(context): refused as \(Self.short(error)), not as malformed XML")
                }
            case .success(let read):
                if mutation.expected != .refuseOrRoundTrip { Issue.record("\(context): a file with a DTD decodes") }
                if (try? TranscriptStore.decode(TranscriptStore.encode(read))) != read {
                    Issue.record("\(context): the words encode and decode unequal")
                }
            }
            let opened = try open(mutation.data, at: "\(transcriptsFolderName)/\(transcript.file).xml", context)
            if case .failure(let error) = opened {
                Issue.record("\(context): the package does not open: \(Self.short(error))")
            }
        }
        Self.check(tally, families: families, eachRefuses: false, test: test, seed: seed)
    }
}

extension SessionFileFuzzTests.Tally {
    mutating func add<Value>(_ result: Result<Value, SessionFileError>, _ expected: Expected) {
        cases += 1
        expected.counted.map { self.expected[$0, default: 0] += 1 }
        switch result {
        case .failure(let error):
            refused += 1
            if error != .malformedXML { parsed += 1 }
        case .success:
            parsed += 1
            opened += 1
        }
    }
}

extension Expected {
    /// The name of a kind that the family counts print, or nil for a plain case.
    var counted: String? {
        switch self {
        case .refuseOrRoundTrip: nil
        case .malformed: "markup"
        case .refused: "reference DTD"
        case .pathRefused: "outside"
        case .pathKept: "inside"
        }
    }
}
