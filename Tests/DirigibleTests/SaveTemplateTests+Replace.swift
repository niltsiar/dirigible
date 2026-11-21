import DirigibleAudio
import DirigibleCore
import Foundation
import Testing
import os

@testable import DirigibleApp
@testable import DirigibleAudio

/// Replace in Save as Template (decision 0079, code gate 1 item 1): a held package never moves, and the old
/// template leaves only after the new one is saved.
extension SaveTemplateTests {
    /// The window of an open template saves over its own name: the package stays where the window holds it.
    @Test func replaceRefusesATemplateThatAWindowHasOpen() async throws {
        defer { clean() }
        let old = try await existing("Show", tracks: 1)
        let model = await app.open(old)
        let studio = try #require(await model.opened() ? model.studio : nil)
        panels.name = "Show"
        panels.replace = true

        await model.saveAsTemplate()

        #expect(model.alert == .templateOpen("Show"), "the window says that the template is open")
        #expect(try FileManager.default.contentsOfDirectory(atPath: trash.path).isEmpty, "nothing went to the Trash")
        #expect(
            PackageID.same(studio.lock.identity, PackageID(lockFileOf: old)),
            "the window holds the package at its old place")
        #expect(try FileManager.default.contentsOfDirectory(atPath: templates.path) == ["Show.dirigible"])
        await model.close()
    }

    /// Another window holds the template: Replace from a second window does not move it.
    @Test func replaceRefusesATemplateThatAnotherWindowHasOpen() async throws {
        defer { clean() }
        let old = try await existing("Show", tracks: 1)
        let holder = await app.open(old)
        let held = try #require(await holder.opened() ? holder.studio : nil)
        let (model, _) = try await window()
        panels.name = "Show"
        panels.replace = true

        await model.saveAsTemplate()

        #expect(model.alert == .templateOpen("Show"))
        #expect(
            PackageID.same(held.lock.identity, PackageID(lockFileOf: old)),
            "the other window holds the package at its old place")
        #expect(try templateTracks("Show") == ["t1"], "the old template stays")
        await model.close()
        await holder.close()
    }

    /// A save that stops after Replace keeps the old template, and nothing goes to the Trash.
    @Test func aStoppedSaveKeepsTheOldTemplate() async throws {
        defer { clean() }
        let old = try await existing("Show", tracks: 1)
        let before = try Data(contentsOf: old.appending(path: "session.xml"))
        let (model, studio) = try await window(tracks: 1, seconds: 40)
        studio.environment.templateCanClone = { _, _ in false }
        let held = OSAllocatedUnfairLock(initialState: false)
        let gate = DispatchSemaphore(value: 0)
        studio.environment.templateWritten = { _, _ in
            held.withLock { $0 = true }
            gate.wait()
            gate.signal()
        }
        panels.name = "Show"
        panels.replace = true

        let save = Task { await model.saveAsTemplate() }
        await until("the copy holds in a write") { held.withLock { $0 } }
        studio.cancelExport()
        gate.signal()
        await save.value

        #expect(FileManager.default.contents(atPath: old.appending(path: "session.xml").path) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: trash.path).isEmpty, "nothing went to the Trash")
        #expect(try FileManager.default.contentsOfDirectory(atPath: templates.path) == ["Show.dirigible"])
        #expect(model.alert == nil, "Cancel shows no alert")
        await model.close()
    }
}
