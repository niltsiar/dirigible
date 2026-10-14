import AppKit
import DirigibleAudio
import DirigibleCore
import DirigibleMCP
import Foundation
import Testing

@testable import DirigibleApp

/// The agent log of the window (decision 0050, C16): each end of an agent request adds one line.
extension ConsentTests {
    /// The fields at `column` of the agent log of `model` (by default the event), after each
    /// queued write.
    func loggedEvents(_ model: SessionWindow, column: Int = 1) throws -> [String] {
        AgentLogWriter.drain()
        let file = model.url.appending(path: AgentLog.fileName)
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").dropFirst(2)
        return lines.map { String($0.split(separator: "\t")[column]) }
    }

    /// `click`, `grant`, `declined`, `no-answer`, and `refused` (here an unknown track, refused
    /// before a sheet, with the cause in the reason) each add one line; a take of the person
    /// (Command-R) adds none.
    @Test(arguments: ["click", "grant", "declined", "no-answer", "refused", "person"])
    func eachEndAddsOneLine(_ end: String) async throws {
        let (model, studio) = try await window()
        var expected = [end]
        switch end {
        case "click":
            _ = try await clickTake(model)
        case "grant":
            try await giveGrant(model, studio)
            #expect(await ask(model, seconds: 0.3, connection: Self.seven).value.isStarted)
            expected = ["click", "grant"]
        case "declined":
            let answer = ask(model)
            _ = try await sheet(model)
            await model.answerConsent(record: false)
            #expect(await answer.value == .declined)
        case "no-answer":
            model.consentWait = { _ in }
            #expect(await ask(model).value == .noAnswer)
        case "refused":
            #expect(await ask(model, ["x"]).value == .refused(.session(.unknownTrack("x"))))
        default:
            model.armed = ["t1"]
            await model.record()
            expected = []
        }
        await model.stop()
        await until("the take ends") { studio.transport == .idle }
        #expect(try loggedEvents(model) == expected)
        if end == "refused" {
            let reason = try loggedEvents(model, column: 7)
            #expect(
                reason.count == 1 && reason[0].hasPrefix("error ") && reason[0].contains("unknownTrack"), "\(reason)")
        }
        await model.close()
    }

    /// A log that the app cannot write (here a folder with the file name) adds no line, and the
    /// take records on.
    @Test func aWriteFailureKeepsTheTake() async throws {
        let (model, studio) = try await window()
        try FileManager.default.createDirectory(
            at: model.url.appending(path: AgentLog.fileName), withIntermediateDirectories: false)
        _ = try await clickTake(model)
        AgentLogWriter.drain()
        #expect(studio.transport == .recording(take: 1))
        await model.stop()
        await model.close()
    }
}

extension RecordAnswer {
    fileprivate var isStarted: Bool {
        if case .started = self { return true }
        return false
    }
}
