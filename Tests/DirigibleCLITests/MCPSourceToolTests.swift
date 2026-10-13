import CoreAudio
import Foundation
import Testing

@testable import DirigibleAudio

/// The tools `devices` and `apps` (run 2026-10-13-agent-workflows, W2, W4, W17): they read this
/// Mac, not a package, so they take no argument.
struct MCPSourceToolTests {
    /// W2, a live smoke check: each tool gives the lines of its command. The lists of this Mac can
    /// change between two reads, so the check holds the invariants of `DeviceCommandTests` only.
    @Test func theToolsGiveTheOwnerLines() async throws {
        let answers = try await mcp([toolCall(1, "devices", [:]), toolCall(2, "apps", [:])])
        for (id, fields, empty) in [(1, 4, "No input devices."), (2, 3, "No apps.")] {
            let (text, isError) = toolResult(answer(answers, id: id))
            #expect(!isError, "\(text)")
            guard text != empty else { continue }
            #expect(text.hasSuffix("\n"), "\(text)")
            var keys: Set<Substring> = []
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
                #expect(parts.count == fields && !parts[0].isEmpty, "line \(line)")
                #expect(keys.insert(parts[0]).inserted, "\(parts[0]) repeats")
            }
        }
    }

    /// W4: an argument, also `package`, is refused with the text of an unknown argument.
    @Test func anArgumentIsRefused() async throws {
        let answers = try await mcp([
            toolCall(1, "devices", ["package": "/tmp/Show.dirigible"]), toolCall(2, "apps", ["all": true]),
        ])
        #expect(toolResult(answer(answers, id: 1)) == ("There is no argument \"package\".", true))
        #expect(toolResult(answer(answers, id: 2)) == ("There is no argument \"all\".", true))
    }

    /// W17: a second call of one server reads the list again. The test makes an aggregate device
    /// over the first input device between the calls, as the app-tap code makes one. It is not
    /// private, so the server process sees it. With no input device, the test cannot make one.
    @Test func aSecondCallSeesANewDevice() async throws {
        removeTestAggregates()
        let uid = "\(testAggregatePrefix)\(UUID().uuidString)"
        var made: AudioObjectID?
        defer { made.map { _ = AudioHardwareDestroyAggregateDevice($0) } }
        let answers = try await mcpInSteps([
            (toolCall(1, "devices", [:]), { _ in }),
            (
                toolCall(2, "devices", [:]),
                { first in
                    guard let sub = first.split(separator: "\t").first.map(String.init) else { return }
                    made = makeAggregate(uid: uid, over: sub)
                }
            ),
        ])
        try #require(answers.count == 2, "\(answers)")
        let (first, second) = (answers[0], answers[1])
        guard !first.hasPrefix("No input devices.") else { return }
        #expect(made != nil, "no aggregate device over the first device of \(first)")
        #expect(!first.contains(uid), "the first list has the new device")
        #expect(second.contains(uid), "the second call gives an old list: \(second)")
    }
}

private let testAggregatePrefix = "dirigible-test-"

/// The text of one tool answer line.
private func toolText(_ line: String) -> String {
    let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
    return toolResult(object ?? [:]).text
}

/// A non-private aggregate device over the device `sub`, or nil.
private func makeAggregate(uid: String, over sub: String) -> AudioObjectID? {
    let description: [String: Any] = [
        kAudioAggregateDeviceUIDKey: uid, kAudioAggregateDeviceNameKey: "Dirigible test",
        kAudioAggregateDeviceIsPrivateKey: 0, kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: sub]],
    ]
    var id = AudioObjectID(kAudioObjectUnknown)
    return AudioHardwareCreateAggregateDevice(description as CFDictionary, &id) == noErr ? id : nil
}

/// Removes each aggregate device of an earlier run that stopped before its `defer`.
private func removeTestAggregates() {
    let system = AudioObjectID(kAudioObjectSystemObject)
    for id in (try? readArray(system, kAudioHardwarePropertyDevices, as: AudioObjectID.self)) ?? []
    where readString(id, kAudioDevicePropertyDeviceUID)?.hasPrefix(testAggregatePrefix) == true {
        _ = AudioHardwareDestroyAggregateDevice(id)
    }
}

/// Starts `dirigible mcp` with a pipe on stdin. For each step, it runs `before` with the tool text
/// of the last answer, writes the line, and waits for its answer line while stdin stays open, as
/// `mcpOverPipe` does. So a step runs between two calls of one server process. Gives the tool
/// text of each answer.
private func mcpInSteps(
    _ steps: [(line: String, before: (String) -> Void)], limit: Duration = .seconds(30)
) async throws -> [String] {
    let folder = FileManager.default.temporaryDirectory.appending(path: "dirigible-mcp-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let output = folder.appending(path: "stdout")
    FileManager.default.createFile(atPath: output.path, contents: nil)
    let stdin = Pipe()
    let process = childProcess(dirigibleBinary, ["mcp"], in: folder)
    process.standardInput = stdin
    process.standardOutput = try FileHandle(forWritingTo: output)
    await Slots.shared.started()
    defer { Slots.shared.ended() }
    try process.run()
    defer { if process.isRunning { process.terminate() } }

    var answers: [String] = []
    let clock = ContinuousClock()
    for (index, step) in steps.enumerated() {
        step.before(answers.last ?? "")
        stdin.fileHandleForWriting.write(Data((step.line + "\n").utf8))
        let deadline = clock.now + limit
        while clock.now < deadline {
            let lines = String(decoding: try Data(contentsOf: output), as: UTF8.self).split(separator: "\n")
            if lines.count > answers.count {
                answers.append(toolText(String(lines[answers.count])))
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard answers.count == index + 1 else { break }
    }
    try stdin.fileHandleForWriting.close()
    return answers
}
