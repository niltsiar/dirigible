import DirigibleCore
import Foundation
import Testing

/// SplitMix64, so each seed gives the same cases on each run.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

/// What a package folder holds: each entry by its relative path, with the kind of the entry
/// (`lstat`), the bytes of a regular file, and the text of a link. It never opens a FIFO and never
/// follows a link, so a hostile item cannot stop it.
struct PackageSnapshot: Equatable {
    enum Entry: Equatable {
        case file(Data)
        case folder
        case link(String)
        case other(UInt16)
    }

    private(set) var entries: [String: Entry] = [:]

    init(of root: URL) throws {
        try walk(root, relative: "")
    }

    private mutating func walk(_ root: URL, relative: String) throws {
        let folder = relative.isEmpty ? root.path : root.path + "/" + relative
        for name in try FileManager.default.contentsOfDirectory(atPath: folder) {
            let path = relative.isEmpty ? name : relative + "/" + name
            let full = root.path + "/" + path
            var info = stat()
            guard lstat(full, &info) == 0 else {
                entries[path] = .other(0)
                continue
            }
            switch info.st_mode & S_IFMT {
            case S_IFREG: entries[path] = .file(try Data(contentsOf: URL(filePath: full)))
            case S_IFLNK: entries[path] = .link(try FileManager.default.destinationOfSymbolicLink(atPath: full))
            case S_IFDIR:
                entries[path] = .folder
                try walk(root, relative: path)
            default: entries[path] = .other(UInt16(info.st_mode & S_IFMT))
            }
        }
    }

    mutating func remove(_ path: String) { entries[path] = nil }

    /// The paths and kinds that differ from `other`, for an issue text.
    func difference(from other: PackageSnapshot) -> String {
        let paths = Set(entries.keys).union(other.entries.keys).sorted()
        let changed = paths.filter { entries[$0] != other.entries[$0] }
        return changed.map { path in
            switch (other.entries[path], entries[path]) {
            case (nil, _): "\(path) added"
            case (_, nil): "\(path) removed"
            default: "\(path) changed"
            }
        }.joined(separator: ", ")
    }
}

/// One `dirigible` child of a fuzz test: the arguments (with `@PKG@` for the package path and
/// `@CASE@` for the case folder), the exit codes that a typed refusal or an accept can give, and an
/// edit of the package copy before the baseline snapshot.
struct FuzzCase: Sendable {
    var family: String
    var arguments: [String]
    var allowed: Set<Int32>
    var prepare: (@Sendable (URL) throws -> Void)?
    /// A text that the stderr of a refusal must hold, when the case knows its refusal.
    var stderrHolds: String?
    var note = ""
}

/// The folder of one fuzz test run: a fixture package, an empty stdin, and one folder for each
/// case with its own copy of the package and a `work` folder for the child. The test removes it.
struct FuzzRun: Sendable {
    let root: URL
    let fixture: URL
    let stdin: URL
    let baseline: PackageSnapshot
    let seed: UInt64
    let test: String

    /// The fixture is `source`, the session of `MCPToolTests` by default, as a package with a
    /// `.lock`: the lock is taken once here, so no case adds the file.
    init(test: String, seed: UInt64, source: () throws -> TemporaryPackage = { try MCPToolTests().package }) throws {
        self.test = test
        self.seed = seed
        root = FileManager.default.temporaryDirectory.appending(path: "dirigible-fuzz-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        fixture = root.appending(path: "Fixture.dirigible")
        let package = try source()
        _ = try PackageLock(package.url)
        try FileManager.default.copyItem(at: package.url, to: fixture)
        stdin = root.appending(path: "stdin")
        try Data().write(to: stdin)
        baseline = try PackageSnapshot(of: fixture)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    /// A new case folder: `Show.dirigible` (a copy of the fixture), `work`, and `Elsewhere`, where
    /// the link targets of a case go.
    func caseFolder(_ index: Int) throws -> URL {
        let folder = root.appending(path: "case-\(index)")
        for name in ["work", "Elsewhere"] {
            try FileManager.default.createDirectory(at: folder.appending(path: name), withIntermediateDirectories: true)
        }
        try FileManager.default.copyItem(at: fixture, to: folder.appending(path: "Show.dirigible"))
        return folder
    }

    /// Replaces the package at `package` with a new copy of the fixture, for a case that runs again.
    func renew(_ package: URL) throws {
        try FileManager.default.removeItem(at: package)
        try FileManager.default.copyItem(at: fixture, to: package)
    }

    func text(_ fuzzCase: FuzzCase, index: Int) -> String {
        let line = fuzzCase.arguments.map { $0.count > 80 ? String($0.prefix(80)) + "...(\($0.count))" : $0 }
        return
            "\(test) seed \(seed) case \(index) family \(fuzzCase.family) \(fuzzCase.note): dirigible \(line.joined(separator: " "))"
    }

    /// Runs one case and gives its problems. A nonzero exit has an `Error:` line and keeps the
    /// package; exit 0 has none and leaves a package that reads. The exit is in the allowed set,
    /// and a signal is a problem whatever its number.
    func execute(_ fuzzCase: FuzzCase, index: Int) async -> [String] {
        let label = text(fuzzCase, index: index)
        do {
            let folder = try caseFolder(index)
            defer { try? FileManager.default.removeItem(at: folder) }
            let package = folder.appending(path: "Show.dirigible")
            try fuzzCase.prepare?(package)
            let before = try PackageSnapshot(of: package)
            let arguments = fuzzCase.arguments.map {
                $0.replacing("@PKG@", with: package.path).replacing("@CASE@", with: folder.path)
            }
            let result = try await dirigible(arguments, input: stdin, directory: folder.appending(path: "work"))
            let after = try PackageSnapshot(of: package)
            var problems: [String] = []
            if result.signaled {
                problems.append("ended by signal \(result.status): stderr \(result.stderr.prefix(300))")
            } else if !fuzzCase.allowed.contains(result.status) {
                problems.append(
                    "exit \(result.status), not one of \(fuzzCase.allowed.sorted()): stderr \(result.stderr.prefix(300))"
                )
            }
            if let text = fuzzCase.stderrHolds, !result.stderr.contains(text) {
                problems.append("stderr lacks \"\(text)\": \(result.stderr.prefix(300))")
            }
            let hasError = result.stderr.split(separator: "\n").contains { $0.hasPrefix("Error:") }
            if result.status != 0 {
                if !hasError {
                    problems.append("exit \(result.status) with no Error: line: stderr \(result.stderr.prefix(300))")
                }
                if after != before {
                    problems.append("exit \(result.status) changed the package: \(after.difference(from: before))")
                }
            } else {
                if hasError { problems.append("exit 0 with an Error: line: \(result.stderr.prefix(300))") }
                if (try? Session(contentsOf: package)) == nil {
                    problems.append("exit 0 left a package that does not read")
                }
            }
            return problems.map { "\(label): \($0)" }
        } catch {
            return ["\(label): the test failed to run the case: \(error)"]
        }
    }

    /// Runs `cases` with at most `width` in flight and records each problem as an issue.
    /// It gives the count of cases and the count of exits of each status, for the tally.
    func run(_ cases: [FuzzCase], width: Int = 32) async -> [String] {
        var problems: [String] = []
        await withTaskGroup(of: [String].self) { group in
            var next = 0
            func add() {
                guard next < cases.count else { return }
                let (index, fuzzCase) = (next, cases[next])
                next += 1
                group.addTask { await execute(fuzzCase, index: index) }
            }
            for _ in 0..<width { add() }
            for await found in group {
                problems += found
                add()
            }
        }
        return problems
    }
}

/// An argument of a command in the `--experimental-dump-help` JSON.
struct ToolArgument: Decodable, Sendable {
    struct Name: Decodable, Sendable {
        var kind: String
        var name: String
    }
    var kind: String
    var isOptional: Bool
    var isRepeating: Bool
    var names: [Name]?
    var valueName: String?
    var allValues: [String]?

    var isPositional: Bool { kind == "positional" }
    var isOption: Bool { kind == "option" }
    var isPackage: Bool { isPositional && valueName == "package" }
    /// `--name` of a value option.
    var flag: String { "--" + (names?.first { $0.kind == "long" }?.name ?? valueName ?? "") }
    /// The name that a table of values keys on.
    var key: String { isOption ? String(flag.dropFirst(2)) : (valueName ?? "") }
}

/// A command of the tree.
struct ToolCommand: Decodable, Sendable {
    var commandName: String
    var arguments: [ToolArgument]?
    var subcommands: [ToolCommand]?
}

struct ToolInfo: Decodable, Sendable {
    var serializationVersion: Int
    var command: ToolCommand
}

/// A command with no subcommand, with the words that name it.
struct Leaf: Sendable {
    var words: [String]
    var arguments: [ToolArgument]
    var name: String { words.joined(separator: " ") }
    var hasRepeatingPositional: Bool { arguments.contains { $0.isPositional && $0.isRepeating } }

    static func all(of tree: ToolInfo) -> [Leaf] {
        func walk(_ command: ToolCommand, _ words: [String]) -> [Leaf] {
            guard let subcommands = command.subcommands, !subcommands.isEmpty else {
                return [Leaf(words: words, arguments: command.arguments ?? [])]
            }
            return subcommands.flatMap { walk($0, words + [$0.commandName]) }
        }
        return walk(tree.command, [])
    }

    /// The tree of the built binary. It asserts the version and the leaves that a fuzz test needs,
    /// so an empty walk fails.
    static func tree() async throws -> [Leaf] {
        let result = try await dirigible("--experimental-dump-help")
        try #require(result.status == 0, "dump-help: \(result)")
        let info = try JSONDecoder().decode(ToolInfo.self, from: Data(result.stdout.utf8))
        #expect(info.serializationVersion == 0)
        let leaves = all(of: info)
        let names = Set(leaves.map(\.name))
        #expect(names.isSuperset(of: ["info", "track rename", "marker set"]), "the leaf set is \(names.sorted())")
        return leaves
    }

    /// Commands that a fuzz test does not run: `cases-cli.md` (the audio hardware, the app, a
    /// model) and the `help` command of swift-argument-parser.
    static let skipped: Set<String> = ["record", "devices", "apps", "mcp", "help"]
    /// Commands that read a model file or the journals of this Mac: family S only.
    static let structureOnly: Set<String> = ["model check", "transcribe", "diagnostics collect"]
}

/// The values that a case gives to a command argument.
enum FuzzValues {
    /// A value that can pass the parse of the argument `key`: a frame, a number, or a word.
    static func sample(_ argument: ToolArgument) -> String {
        if argument.isPackage { return "@PKG@" }
        switch argument.key {
        case "out": return "@CASE@/work/out.wav"
        case "layout": return "mono"
        case "kind": return "marker"
        case "edge": return "start"
        case let key where numeric.contains(key): return "1000"
        default: return "a"
        }
    }

    static let numeric: Set<String> = [
        "at", "from", "to", "start", "length", "offset", "by", "db", "frame", "frames", "until", "latency",
        "sample-time", "host-time", "nominal-rate", "measured-rate", "sample-rate", "bits", "rate", "take",
        "limit", "depth", "attack", "release", "reduction", "hum", "rumble", "clipping", "sibilance",
        "sibilance-hz", "threshold", "min-length", "window", "step", "days", "seconds", "pre-roll", "playhead",
        "episode", "season", "ramp", "in", "keep", "point", "bitrate", "resampled-from",
    ]

    /// The stress values of `cases-cli.md` family V.
    static let stress: [String] =
        [
            "-1", "0", "1", "1099511627776", "1099511627777", "9223372036854775807", "-9223372036854775808",
            "9223372036854775808", "9007199254740993", "1e400", "nan", "inf", "-inf", "-0", "1.5", "0x10", "1_000",
            "+1", "1,2", "1,", ",", "1,2,3", "0,0", "", " ", String(repeating: "x", count: 65_536),
            "a\tb\nc\u{FFFE}\u{1F399}", "zz-none", "../out.wav", "out.zz", "out.srt", "out.vtt", "out.wav",
            "@CASE@/out.mp3", "@PKG@/inside.wav", "-",
        ]

    /// A value of a named option that the table of a reason names, each once (family V0): a
    /// `channels` list for `parseChannels`, a gain that is not finite for `parseGain`, and the edges
    /// of a frame.
    static let named: [String: [String]] = [
        "channels": ["1,2", "1,", ",", "1,2,3", "0,0"],
        "db": ["nan", "inf", "-inf", "1e400", "-0", "+1", "1.5"],
        "at": ["1099511627777", "9223372036854775807"],
        "from": ["1099511627777", "9223372036854775807"],
        "to": ["1099511627777", "-9223372036854775808"],
        "start": ["1099511627777", "9223372036854775807"],
        "length": ["1099511627777", "9223372036854775807"],
        "by": ["9223372036854775807", "-9223372036854775808"],
        "offset": ["9223372036854775807"],
    ]
}

/// Arguments of a command from a sample for each required argument, with some values replaced.
struct ArgumentList {
    let leaf: Leaf

    /// `values` replaces or adds the value of the argument at an index. `twice` gives an option a
    /// second value. A positional goes first, then each option.
    func make(values: [Int: String] = [:], twice: (index: Int, value: String)? = nil, without: Set<Int> = [])
        -> [String]
    {
        var positionals: [String] = []
        var options: [String] = []
        for (index, argument) in leaf.arguments.enumerated() where !without.contains(index) {
            if argument.isPositional {
                if let value = values[index] {
                    positionals.append(value)
                } else if !argument.isOptional {
                    positionals.append(FuzzValues.sample(argument))
                }
            } else if argument.isOption {
                if let value = values[index] {
                    options += [argument.flag, value]
                } else if !argument.isOptional {
                    options += [argument.flag, FuzzValues.sample(argument)]
                }
                if let twice, twice.index == index { options += [argument.flag, twice.value] }
            }
        }
        return leaf.words + positionals + options
    }
}
