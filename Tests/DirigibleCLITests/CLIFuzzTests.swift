import DirigibleCore
import Foundation
import Testing

/// C8 to C10, C13, C14: the `dirigible` command line, walked from `--experimental-dump-help`, with
/// seeded wrong structures (family S), stress values (V), and damaged packages (D). Each case runs
/// in a child on its own copy of the package. A case ends by an exit in its set, with an `Error:`
/// line on a refusal, and a refusal keeps each byte of the package. Each issue names the seed, the
/// case, and the family.
struct CLIFuzzTests {
    static let seeds: [UInt64] = [20_261_117]

    /// The count of cases of each family, one line each, for the slice log.
    static func tally(_ test: String, seed: UInt64, _ cases: [FuzzCase]) {
        for (family, count) in Dictionary(grouping: cases, by: \.family).mapValues(\.count).sorted(by: {
            $0.key < $1.key
        }) {
            print("\(test) seed \(seed) family \(family): \(count) cases")
        }
    }

    @Test func theSnapshotSeesOneChangedByte() throws {
        let run = try FuzzRun(test: "theSnapshotSeesOneChangedByte", seed: 0)
        defer { run.remove() }
        let copy = try run.caseFolder(0).appending(path: "Show.dirigible")
        #expect(try PackageSnapshot(of: copy) == run.baseline, "a copy is equal")

        let xml = copy.appending(path: "session.xml")
        var bytes = try Data(contentsOf: xml)
        bytes[10] ^= 1
        try bytes.write(to: xml)
        let changed = try PackageSnapshot(of: copy)

        #expect(changed != run.baseline, "one changed byte differs")
        #expect(changed.difference(from: run.baseline) == "session.xml changed")
    }

    // MARK: Family S

    /// The seven wrong shapes of `cases-cli.md` for one command.
    static func structureCases(_ leaf: Leaf, _ random: inout SplitMix) -> [FuzzCase] {
        let list = ArgumentList(leaf: leaf)
        let base = list.make()
        let strict: Set<Int32> = [64]
        // A repeating positional takes one more value, and the command then refuses it itself.
        let tail: Set<Int32> = leaf.hasRepeatingPositional ? [1, 2, 64] : strict
        func make(_ family: String, _ arguments: [String], _ allowed: Set<Int32>) -> FuzzCase {
            FuzzCase(family: family, command: leaf.name, arguments: arguments, allowed: allowed)
        }
        var cases = [make("S1", base + ["--zz-unknown"], strict), make("S2", base + ["--zz-unknown=1"], strict)]
        let required = leaf.arguments.indices.filter { !leaf.arguments[$0].isOptional }
        if let index = required.randomElement(using: &random) {
            cases.append(make("S3", list.make(without: [index]), strict))
        }
        if let index = leaf.arguments.indices.filter({ leaf.arguments[$0].isOption }).randomElement(using: &random) {
            cases.append(make("S4", list.make(without: [index]) + [leaf.arguments[index].flag], strict))
        }
        for (index, argument) in leaf.arguments.enumerated() {
            guard let first = argument.allValues?.first, argument.isOption || argument.isPositional else { continue }
            for value in [first.prefix(1).uppercased() + first.dropFirst(), "", first + " "] {
                cases.append(make("S5", list.make(values: [index: value]), strict))
            }
        }
        cases.append(make("S6", base + ["zz-extra"], tail))
        let options = Array(base.dropFirst(leaf.words.count))
        cases.append(make("S7", leaf.words + ["--"] + options + ["--zz-unknown"], tail))
        return cases
    }

    @Test(arguments: seeds)
    func badArgumentStructureExits64(seed: UInt64) async throws {
        let leaves = try await Leaf.tree().filter { !Leaf.skipped.contains($0.name) }
        var random = SplitMix(seed: seed)
        let cases = leaves.flatMap { Self.structureCases($0, &random) }
        let run = try FuzzRun(test: "badArgumentStructureExits64", seed: seed)
        defer { run.remove() }
        Self.tally("badArgumentStructureExits64", seed: seed, cases)

        for problem in await run.run(cases) { Issue.record(Comment(rawValue: problem)) }
    }

    // MARK: Family V

    /// The V0 cases (a named value for a named option), then two V1 cases (one to three values) and one V2 case
    /// (an option twice) of the leaf.
    static func valueCases(_ leaf: Leaf, _ random: inout SplitMix) -> [FuzzCase] {
        let list = ArgumentList(leaf: leaf)
        let arguments = leaf.arguments
        let candidates = arguments.indices.filter {
            arguments[$0].isOption || (arguments[$0].isPositional && !arguments[$0].isPackage)
        }
        guard !candidates.isEmpty else { return [] }
        let allowed: Set<Int32> = [0, 1, 2, 3, 64]
        func make(_ family: String, _ arguments: [String], _ note: String = "") -> FuzzCase {
            FuzzCase(family: family, command: leaf.name, arguments: arguments, allowed: allowed, note: note)
        }
        var cases: [FuzzCase] = []
        for index in candidates {
            for value in FuzzValues.named[arguments[index].key] ?? [] {
                cases.append(make("V0", list.make(values: [index: value])))
            }
        }
        for _ in 0..<2 {
            let count = Int.random(in: 1...min(3, candidates.count), using: &random)
            let chosen = candidates.shuffled(using: &random).prefix(count)
            let values = Dictionary(
                uniqueKeysWithValues: chosen.map { ($0, FuzzValues.stress.randomElement(using: &random)!) })
            cases.append(make("V1", list.make(values: values)))
        }
        if let index = candidates.filter({ arguments[$0].isOption }).randomElement(using: &random) {
            let first = FuzzValues.stress.randomElement(using: &random)!
            let second = FuzzValues.stress.randomElement(using: &random)!
            cases.append(make("V2", list.make(values: [index: first], twice: (index, second))))
        }
        return cases
    }

    @Test(arguments: seeds)
    func stressValuesKeepThePackageOnRefusal(seed: UInt64) async throws {
        let leaves = try await Leaf.tree().filter {
            !Leaf.skipped.contains($0.name) && !Leaf.structureOnly.contains($0.name)
        }
        var random = SplitMix(seed: seed)
        let cases = leaves.flatMap { Self.valueCases($0, &random) }
        let run = try FuzzRun(test: "stressValuesKeepThePackageOnRefusal", seed: seed)
        defer { run.remove() }
        Self.tally("stressValuesKeepThePackageOnRefusal", seed: seed, cases)

        for problem in await run.run(cases) { Issue.record(Comment(rawValue: problem)) }
    }

    // MARK: Family D

    static let declaration = #"<?xml version="1.0" encoding="UTF-8"?>"#
    static let root = HostileSessionCommandTests.root

    /// The nested input of a pin: `depth - 1` closed unknown elements in the root (X8, X9).
    static func nested(depth: Int) -> String {
        declaration + "\n" + root + String(repeating: "<a>", count: depth - 1)
            + String(repeating: "</a>", count: depth - 1) + "</session>\n"
    }

    /// The origin of "a NR" (300,000 frames) in "z" (1,000,000 frames) at `offset` (X10, X11).
    static func origin(offset: String) -> String {
        let files =
            #"<files><file id="a NR" path="a NR.wav" channels="1" length="300000">"#
            + #"<origin source="z" offset="\#(offset)" gain="0"><hum hz="50"/></origin></file>"#
            + #"<file id="z" path="z.wav" channels="1" length="1000000"/></files>"#
        return declaration + "\n" + root.replacing(#"version="12""#, with: #"version="14""#) + files + "</session>\n"
    }

    /// The pins of S1 and S2 as cases through `dirigible info` (D3): each input that meets a
    /// refusal, with the near input that does not.
    static func pinnedCases() -> [FuzzCase] {
        let notASession = "is not a Dirigible session file."
        let name = String(repeating: "n", count: 60_000)
        func pin(_ note: String, _ xml: String, _ code: Int32, _ text: String?) -> FuzzCase {
            FuzzCase(
                family: "D3", command: "info", arguments: ["info", "@PKG@"], allowed: [code],
                prepare: { try Data(xml.utf8).write(to: $0.appending(path: "session.xml")) }, stderrHolds: text,
                note: note)
        }
        return [
            pin("X7 100,000 unclosed", declaration + "\n" + root + HostileSessionCommandTests.unclosed, 2, notASession),
            pin(
                "X22 long name then deep",
                declaration + "\n" + root + "<\(name)>" + HostileSessionCommandTests.unclosed,
                2, notASession),
            pin("X9 depth 65", nested(depth: 65), 2, notASession),
            pin("X8 depth 64", nested(depth: 64), 0, nil),
            pin(
                "X10 offset Int.max", origin(offset: "9223372036854775807"), 2,
                "has an origin that names no matching source range."),
            pin("X12 offset 700001", origin(offset: "700001"), 2, "has an origin that names no matching source range."),
            pin("X11 offset 700000", origin(offset: "700000"), 0, nil),
        ]
    }

    @Test(arguments: seeds)
    func damagedPackagesRefuseWithNoCrash(seed: UInt64) async throws {
        _ = try await Leaf.tree()
        let run = try FuzzRun(test: "damagedPackagesRefuseWithNoCrash", seed: seed)
        defer { run.remove() }
        let size = try Data(contentsOf: run.fixture.appending(path: "session.xml")).count
        var random = SplitMix(seed: seed)
        let commands = [["info", "@PKG@"], ["info", "@PKG@", "--json"], ["track", "rename", "@PKG@", "a", "X"]]
        var cases: [FuzzCase] = []
        for index in 0..<40 {
            let command = commands[index % commands.count]
            let family: String
            let prepare: @Sendable (URL) throws -> Void
            if index % 2 == 0 {
                family = "D1"
                let edits = (0..<Int.random(in: 1...8, using: &random)).map { _ in
                    (offset: Int.random(in: 0..<size, using: &random), byte: UInt8.random(in: 0...255, using: &random))
                }
                prepare = { package in
                    let file = package.appending(path: "session.xml")
                    var bytes = try Data(contentsOf: file)
                    for edit in edits { bytes[edit.offset] = edit.byte }
                    try bytes.write(to: file)
                }
            } else {
                family = "D2"
                let cut = Int.random(in: 0..<size, using: &random)
                prepare = { package in
                    let file = package.appending(path: "session.xml")
                    try Data(contentsOf: file).prefix(cut).write(to: file)
                }
            }
            cases.append(
                FuzzCase(
                    family: family, command: command.joined(separator: " "), arguments: command, allowed: [0, 1, 2],
                    prepare: prepare))
        }
        cases += Self.pinnedCases()
        Self.tally("damagedPackagesRefuseWithNoCrash", seed: seed, cases)

        for problem in await run.run(cases) { Issue.record(Comment(rawValue: problem)) }
    }
}
