import Foundation
import Testing

/// The CLI parity rule (AGENTS.md, decision 0011): each public mutating method in DirigibleCore
/// has a `dirigible` command, or an exemption with its reason.
struct ParityTests {
    static let commands: [String: [String]] = [
        "addCapture": ["capture add"],
        "removeCapture": ["capture remove"],
        "addFile": ["file add"],
        "removeFile": ["file remove"],
        "addTrack": ["track add"],
        "addCallTracks": ["track add-call"],
        "removeTrack": ["track remove"],
        "renameTrack": ["track rename"],
        "setGain": ["track gain", "clip gain"],
        "setRoute": ["track route"],
        "setLayout": ["track layout"],
        "setMarker": ["marker set"],
        "removeMarker": ["marker remove"],
        "place": ["clip place"],
        "clear": ["clip clear"],
        "split": ["clip split"],
        "move": ["clip move"],
        "trim": ["clip trim"],
        "paste": ["clip paste"],
        "splitClips": ["clip split-at"],
        "nudge": ["clip nudge"],
        "setFades": ["clip fade"],
        "setGains": ["clip gain"],
        "setCrossfades": ["clip crossfade"],
        "rippleDelete": ["clip ripple-delete"],
        "rippleInsert": ["clip ripple-insert"],
    ]

    static let exemptions: [String: String] = [
        "setRecording": "Only the capture run writes <recording> (decision 0004).",
        "edit": "History lives in one process. Each command is one read-edit-save step.",
        "undo": "History lives in one process. Each command is one read-edit-save step.",
        "redo": "History lives in one process. Each command is one read-edit-save step.",
    ]

    @Test func everyMutatingSessionMethodHasACommandOrAnExemption() throws {
        let names = try publicMutatingMethods()
        #expect(names.count >= 18, "The scan found only \(names.sorted())")
        for name in names.sorted() where Self.commands[name] == nil && Self.exemptions[name] == nil {
            Issue.record("\(name) has no dirigible command and no exemption in ParityTests")
        }
        let stale = Set(Self.commands.keys).union(Self.exemptions.keys).subtracting(names)
        #expect(stale.isEmpty, "ParityTests lists methods that do not exist: \(stale.sorted())")
    }

    @Test func everyListedCommandExists() async throws {
        for command in Self.commands.values.joined().sorted() {
            let result = try await dirigible(command.split(separator: " ").map(String.init) + ["--help"])
            // --help exits 0 for any words, so the usage line proves that the command exists.
            #expect(
                result.stdout.contains("USAGE: dirigible \(command) <package>"), "dirigible \(command) does not exist")
        }
    }

    private func publicMutatingMethods() throws -> Set<String> {
        let core = URL(filePath: #filePath).deletingLastPathComponent()
            .appending(path: "../../Sources/DirigibleCore").standardized
        let files = try FileManager.default.contentsOfDirectory(at: core, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        var names: Set<String> = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in text.matches(of: /public\s+mutating\s+func\s+(\w+)/) { names.insert(String(match.1)) }
        }
        return names
    }
}
