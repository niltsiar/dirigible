import Foundation
import Testing

@testable import DirigibleAudio
@testable import DirigibleCore

/// C18, C19, C14: one item of each kind at one path of a package copy. Each pair runs once, in a
/// seeded order, in a `dirigible` child with a limit of 10 s, and gives the exit of the tables of
/// `cases-cli.md` (decision 0003 item rules), never a signal and never a wait on a FIFO. Nothing in
/// `Elsewhere/`, where the link targets are, changes. Cells of the backlog items 1787 and 1788
/// expect the present behavior.
struct PackageItemFuzzTests {

    enum Kind: String, Sendable {
        case regular, folder, linkToRegular, linkToFolder, linkToFIFO, dangling, fifo, hardLink, selfLink, none
    }

    enum TempState: Sendable { case gone, stays, changed }

    /// The expected end of a child: exit 0, exit 2, or exit 2 with the path in the `Error:` line.
    struct Cell: Sendable {
        var exit: Int32
        var names = false
        var temp: TempState?
        var victimChanged: Bool?
        /// The take is placed, then the flush of a `Clips/` folder with no read access fails: exit 2,
        /// with the WAV in `Clips/` and the sidecar changed, and the take still pending. A second
        /// finalize at 0755 finalizes the take. A hard-link cell gets no second finalize: its
        /// overwritten pool file stays lost (item 1788).
        var placedBeforeFlushFault = false

        init(_ code: Character) {
            exit = code == "0" ? 0 : 2
            names = code == "n"
        }
    }

    struct ItemCase: Sendable {
        var part: String
        var path: String
        var kind: Kind
        /// The folders whose mode is set after the baseline snapshot.
        var modes: [String: mode_t] = [:]
        var arguments: [String]
        var cell: Cell
        var note = ""
    }

    static let backupName = "session-20261009T081530.250Z.xml"
    static let sevenKinds: [Kind] = [.regular, .folder, .linkToRegular, .linkToFolder, .linkToFIFO, .dangling, .fifo]

    /// The session of `MCPToolTests` with a pool file in `Clips/sub`, a transcript, the folders of
    /// a package, and one backup whose session names `r.wav`, which `session.xml` does not name.
    static func fixture() throws -> (package: TemporaryPackage, transcript: String) {
        let package = try MCPToolTests().package
        var session = try package.read()
        try session.addFile(AudioFile(id: "s", path: "sub/n.wav", layout: .mono, length: 480_000))
        let words = try #require(FileWords.Word(file: "f", range: 0..<1000, text: "hello"))
        try session.addTranscript(FileWords([words]), name: "T", derived: [])
        try session.write(to: package.url)
        let transcript = try #require(session.transcripts.values.first).file
        for name in ["Clips/sub", "Transcripts", "Backups", "Artwork", "Capture"] {
            try FileManager.default.createDirectory(
                at: package.url.appending(path: name), withIntermediateDirectories: true)
        }
        var past = session
        try past.addFile(AudioFile(id: "r", path: "r.wav", layout: .mono, length: 1000))
        try past.checkedData().write(to: package.url.appending(path: "Backups/\(backupName)"))
        return (package, "\(transcript)")
    }

    /// Puts `kind` at `path` of `package`, in place of what is there. Link targets go to `elsewhere`.
    static func place(_ kind: Kind, at path: String, package: URL, elsewhere: URL, token: Int, bytes: Data) throws {
        let url = package.appending(path: path)
        let fileManager = FileManager.default
        let original = try? Data(contentsOf: url)
        var info = stat()
        if lstat(url.path, &info) == 0 { try fileManager.removeItem(at: url) }
        let target = elsewhere.appending(path: "target-\(token)")
        switch kind {
        case .none: break
        case .regular: try bytes.write(to: url)
        case .folder: try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
        case .linkToRegular:
            try bytes.write(to: target)
            try fileManager.createSymbolicLink(at: url, withDestinationURL: target)
        case .linkToFolder:
            try fileManager.createDirectory(at: target, withIntermediateDirectories: false)
            try fileManager.createSymbolicLink(at: url, withDestinationURL: target)
        case .linkToFIFO:
            try #require(mkfifo(target.path, 0o644) == 0)
            try fileManager.createSymbolicLink(at: url, withDestinationURL: target)
        case .dangling: try fileManager.createSymbolicLink(at: url, withDestinationURL: target)
        case .fifo: try #require(mkfifo(url.path, 0o644) == 0)
        case .hardLink:
            // The write temp name of a take links to the pool file that it would replace.
            let source = path == temp ? package.appending(path: "Clips/victim.wav") : target
            if path != temp { try (original ?? bytes).write(to: target) }
            try #require(link(source.path, url.path) == 0)
        case .selfLink:
            try fileManager.createSymbolicLink(atPath: url.path, withDestinationPath: url.lastPathComponent)
        }
    }

    static func lists(_ url: URL) -> Bool {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if descriptor >= 0 { close(descriptor) }
        return descriptor >= 0
    }

    /// Runs one case in its own folder and gives its problems.
    static func execute(_ item: ItemCase, index: Int, run: FuzzRun) async -> [String] {
        let label =
            "seed \(run.seed) case \(index) family \(item.part) \(item.kind.rawValue) at \(item.path) modes \(item.modes) \(item.note): dirigible \(item.arguments.joined(separator: " "))"
        var problems: [String] = []
        do {
            let folder = try run.caseFolder(index)
            let package = folder.appending(path: "Show.dirigible")
            let elsewhere = folder.appending(path: "Elsewhere")
            defer {
                for path in item.modes.keys { chmod(package.appending(path: path).path, 0o755) }
                try? FileManager.default.removeItem(at: folder)
            }
            var random = SplitMix(seed: run.seed &+ UInt64(index))
            let bytes = Data((0..<16).map { _ in UInt8.random(in: 0...255, using: &random) })
            try place(item.kind, at: item.path, package: package, elsewhere: elsewhere, token: index, bytes: bytes)
            let before = try PackageSnapshot(of: package)
            let outside = try PackageSnapshot(of: elsewhere)
            for (path, mode) in item.modes {
                let url = package.appending(path: path)
                try #require(chmod(url.path, mode) == 0)
                if mode != 0o755 && lists(url) {
                    problems.append("\(path) at mode \(String(mode, radix: 8)) still lists")
                }
            }
            let arguments = item.arguments.map { $0.replacing("@PKG@", with: package.path) }
            let result = try await dirigible(
                shell: #"exec "$0" "$@""#, arguments: [dirigibleBinary.path] + arguments, limit: .seconds(10))
            for path in item.modes.keys { chmod(package.appending(path: path).path, 0o755) }
            let after = try PackageSnapshot(of: package)
            if try PackageSnapshot(of: elsewhere) != outside { problems.append("Elsewhere changed") }

            let errors = result.stderr.split(separator: "\n").filter { $0.hasPrefix("Error:") }
            if result.signaled {
                problems.append("ended by signal \(result.status): stderr \(result.stderr.prefix(300))")
            } else if result.status != item.cell.exit {
                problems.append("exit \(result.status), not \(item.cell.exit): stderr \(result.stderr.prefix(300))")
            } else if item.cell.exit == 2 {
                if errors.count != 1 { problems.append("\(errors.count) Error: lines: \(result.stderr.prefix(300))") }
                if item.cell.names, !result.stderr.contains("\(package.path)/\(item.path)") {
                    problems.append("the Error: line does not name \(item.path): \(result.stderr.prefix(300))")
                }
            } else if !errors.isEmpty {
                problems.append("exit 0 with an Error: line: \(result.stderr.prefix(300))")
            }
            if result.status == 2 || item.arguments.first == "info" {
                var skipped: Set<String> = item.part == "D4.5" ? [item.path, "Clips/victim.wav"] : []
                if item.cell.placedBeforeFlushFault {
                    skipped.formUnion(["Clips/take1-1-1.wav", "Capture/take1-1-1.sidecar"])
                    if after.entries["Clips/take1-1-1.wav"] == nil { problems.append("the WAV is not in Clips/") }
                }
                var kept = after
                var original = before
                for path in skipped {
                    kept.remove(path)
                    original.remove(path)
                }
                if kept != original { problems.append("the package changed: \(kept.difference(from: original))") }
            } else if (try? Session(contentsOf: package)) == nil {
                problems.append("exit 0 left a package that does not read")
            }
            if let temp = item.cell.temp {
                let state: TempState =
                    after.entries[item.path] == nil
                    ? .gone : (after.entries[item.path] == before.entries[item.path] ? .stays : .changed)
                if state != temp { problems.append("the temp name is \(state), not \(temp)") }
            }
            if let changed = item.cell.victimChanged {
                let victim = after.entries["Clips/victim.wav"] != before.entries["Clips/victim.wav"]
                if victim != changed { problems.append("Clips/victim.wav changed \(victim), not \(changed)") }
            }
            if item.cell.placedBeforeFlushFault, item.kind != .hardLink {
                problems += try await secondFinalizeProblems(package)
            }
        } catch {
            problems.append("the test failed to run the case: \(error)")
        }
        return problems.map { "\(label): \($0)" }
    }

    /// Runs `cases` in a seeded order, at most `width` in flight, and records each problem.
    static func runAll(_ cases: [ItemCase], run: FuzzRun) async {
        var problems: [String] = []
        await withTaskGroup(of: [String].self) { group in
            var next = 0
            func add() {
                guard next < cases.count else { return }
                let (index, item) = (next, cases[next])
                next += 1
                group.addTask { await execute(item, index: index, run: run) }
            }
            for _ in 0..<16 { add() }
            for await found in group {
                problems += found
                add()
            }
        }
        for problem in problems { Issue.record(Comment(rawValue: problem)) }
    }

    static func shuffled(_ cases: [ItemCase], seed: UInt64) -> [ItemCase] {
        var random = SplitMix(seed: seed)
        return cases.shuffled(using: &random)
    }

    /// The cells of a row, one letter for each kind: `0` exit 0, `2` exit 2, `n` exit 2 that names the path.
    static func row(_ kinds: [Kind], _ cells: String) -> [Kind: Cell] {
        Dictionary(uniqueKeysWithValues: zip(kinds, cells.filter { $0 != " " }.map(Cell.init)))
    }

    // MARK: Parts 1 to 4

    static func itemCases(transcript: String) -> [ItemCase] {
        let info = ["info", "@PKG@"]
        let rename = ["track", "rename", "@PKG@", "a", "X"]
        let eight = sevenKinds + [.hardLink]
        var cases: [ItemCase] = []
        func add(
            _ part: String, _ path: String, _ kinds: [Kind], _ cells: String, _ arguments: [String],
            modes: [String: mode_t] = [:], note: String = ""
        ) {
            let cells = row(kinds, cells)
            for kind in kinds {
                cases.append(
                    ItemCase(
                        part: part, path: path, kind: kind, modes: modes, arguments: arguments, cell: cells[kind]!,
                        note: note))
            }
        }
        // Part 1: the items.
        add("D4.1", ".lock", eight, "0 n n n n n n n", info)
        add("D4.1", ".lock", eight, "0 2 n n n n n n", rename)
        add("D4.1", "session.xml", eight, "2 n n n n n n 0", info)
        add("D4.1", "session.xml", eight, "2 n n n n n n 0", rename)
        for folder in ["Clips", "Transcripts", "Backups", "Artwork", "Capture"] {
            add("D4.1", folder, sevenKinds, "n 0 n n n n n", info)
        }
        add("D4.1", "Clips/stray.wav", sevenKinds, "0 0 0 0 n 0 n", info)
        add("D4.1", "Transcripts/stray.xml", sevenKinds, "0 n 0 n n 0 n", info)
        for folder in ["Backups", "Artwork", "Capture"] {
            add("D4.1", "\(folder)/stray.dat", sevenKinds, "0 n n n n n n", info)
        }
        add("D4.1", "Clips/sub/n.wav", sevenKinds, "0 n 0 n n 0 n", info)

        // Part 2: the named paths with no item as a kind too, and the folder mode.
        let named = sevenKinds + [.none]
        for (mode, clips) in [
            (mode_t(0o755), "0 0 0 0 n 0 n 0"), (0o300, "0 n 0 n n 0 n 0"), (0o100, "0 n 0 n n 0 n 0"),
        ] {
            add(
                "D4.2", "Clips/f.wav", named, clips, info, modes: mode == 0o755 ? [:] : ["Clips": mode],
                note: "1787 folder cells")
            add(
                "D4.2", "Transcripts/\(transcript).xml", named, "0 n 0 n n 0 n 0", info,
                modes: mode == 0o755 ? [:] : ["Transcripts": mode])
        }

        // Part 3: items that stat cannot read, each at 0755 and 0300 of its folder.
        for mode in [mode_t(0o755), 0o300] {
            let clips: [String: mode_t] = mode == 0o755 ? [:] : ["Clips": mode]
            add("D4.3", "Clips/f.wav", [.selfLink], "0", info, modes: clips)
            add(
                "D4.3", "Transcripts/\(transcript).xml", [.selfLink], "0", info,
                modes: mode == 0o755 ? [:] : ["Transcripts": mode])
            add(
                "D4.3", "Clips/sub", [.folder], "0", info, modes: clips.merging(["Clips/sub": 0o000]) { $1 },
                note: "EACCES")
            add("D4.3", "Clips/sub", [.regular], "0", info, modes: clips, note: "ENOTDIR")
        }

        // Part 4: the revert of the backup that names r.wav.
        let revert = ["backup", "revert", "@PKG@", "--name", backupName]
        add("D4.4", "Clips/r.wav", sevenKinds, "0 0 0 0 n 0 n", revert, note: "1787 folder cells")
        add(
            "D4.4", "Clips/r.wav", sevenKinds, "0 n 0 n n 0 n", revert, modes: ["Clips": 0o300],
            note: "1787 folder cells")
        return cases
    }

    @Test(arguments: fuzzSeeds)
    func packageItemKindsRefuseOrOpenInTime(seed: UInt64) async throws {
        var transcript = ""
        let run = try FuzzRun(test: "packageItemKindsRefuseOrOpenInTime", seed: seed) {
            let made = try Self.fixture()
            transcript = made.transcript
            return made.package
        }
        defer { run.remove() }
        let cases = Self.shuffled(Self.itemCases(transcript: transcript), seed: seed)
        for (part, count) in Dictionary(grouping: cases, by: \.part).mapValues(\.count).sorted(by: { $0.key < $1.key })
        {
            print("packageItemKindsRefuseOrOpenInTime seed \(seed) family \(part): \(count) cases")
        }

        await Self.runAll(cases, run: run)
    }

    // MARK: Part 5

    static let temp = "Clips/.take1-1-1.wav.tmp"
    static let victim = Data("victim wav".utf8)

    /// A pending take with one armed track and one closed segment, `Clips/`, and `Clips/victim.wav`.
    static func pendingTake() throws -> TemporaryPackage {
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.setRecording(
            Recording(
                take: 1, playheadFrame: 0, takeStartHostTimeNanos: TakeCommandTests.takeStart, armedTracks: ["t1"]))
        let package = try TemporaryPackage(session)
        let capture = package.url.appending(path: "Capture")
        try FileManager.default.createDirectory(at: capture, withIntermediateDirectories: true)
        let header = CaptureHeader(
            deviceUID: "usb-1", deviceName: "USB Mic", nominalRate: 48_000, availableRates: [48_000...48_000],
            channelCount: 1, latency: 0, firstSampleTime: 0, firstHostTimeNanos: TakeCommandTests.takeStart)
        let writer = try SegmentWriter(
            folder: capture, name: SegmentName(take: 1, arm: 1, segment: 1), header: header)
        try writer.checkpoint(Checkpoint(fileFrame: 0, sampleTime: 0, hostTimeNanos: TakeCommandTests.takeStart))
        let samples = [Float](repeating: 0.25, count: 96_000)
        try samples.withUnsafeBufferPointer { try writer.write($0, frames: samples.count) }
        try writer.close()
        let clips = package.url.appending(path: "Clips")
        try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
        try victim.write(to: clips.appending(path: "victim.wav"))
        return package
    }

    static func takeCases() -> [ItemCase] {
        let kinds: [Kind] = [
            .none, .regular, .folder, .linkToRegular, .linkToFolder, .linkToFIFO, .dangling, .fifo, .hardLink,
        ]
        // Exit, then the state of the temp name, for each of 0755, 0300, and 0100.
        let table: [Kind: [(Character, TempState?, Bool?)]] = [
            .none: [("0", nil, nil), ("0", nil, nil), ("2", nil, nil)],
            .regular: [("0", nil, nil), ("0", nil, nil), ("2", .changed, nil)],
            .folder: [("2", .stays, nil), ("2", .stays, nil), ("2", .stays, nil)],
            .linkToRegular: [("0", nil, nil), ("2", .gone, nil), ("2", .stays, nil)],
            .linkToFolder: [("0", nil, nil), ("2", .gone, nil), ("2", .stays, nil)],
            .linkToFIFO: [("n", .stays, nil), ("2", .gone, nil), ("2", .stays, nil)],
            .dangling: [("0", nil, nil), ("2", .gone, nil), ("2", .stays, nil)],
            .fifo: [("n", .stays, nil), ("2", .gone, nil), ("2", .stays, nil)],
            .hardLink: [("0", nil, false), ("0", nil, true), ("2", .changed, true)],
        ]
        var cases: [ItemCase] = []
        for kind in kinds {
            for (index, mode) in [mode_t(0o755), 0o300, 0o100].enumerated() {
                let (code, state, victimChanged) = table[kind]![index]
                var cell = Cell(code)
                cell.temp = state
                cell.victimChanged = victimChanged
                // The flush of `Clips/` needs read access: the take is placed, the flush fails (exit 2).
                if mode == 0o300, code == "0" {
                    cell.exit = 2
                    cell.placedBeforeFlushFault = true
                }
                cases.append(
                    ItemCase(
                        part: "D4.5", path: temp, kind: kind, modes: mode == 0o755 ? [:] : ["Clips": mode],
                        arguments: ["take", "finalize", "@PKG@"], cell: cell,
                        note: kind == .hardLink && mode != 0o755 ? "1788" : ""))
            }
        }
        return cases
    }

    @Test(arguments: fuzzSeeds)
    func clipTempNameKindsRefuseOrFinalizeInTime(seed: UInt64) async throws {
        let run = try FuzzRun(test: "clipTempNameKindsRefuseOrFinalizeInTime", seed: seed) { try Self.pendingTake() }
        defer { run.remove() }
        let cases = Self.shuffled(Self.takeCases(), seed: seed)
        print("clipTempNameKindsRefuseOrFinalizeInTime seed \(seed) family D4.5: \(cases.count) cases")

        await Self.runAll(cases, run: run)
    }
}
