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

    /// A window holds the key of the old template and no lock: here its open failed, as while an open runs.
    /// Replace does not move the package of that window.
    @Test func replaceRefusesATemplateWhoseWindowHasNoLock() async throws {
        defer { clean() }
        let old = try await existing("Show", tracks: 1)
        let unreadable = Data("not a session".utf8)
        try unreadable.write(to: old.appending(path: "session.xml"))
        let holder = await app.open(old)
        await until("the open of the unreadable template fails") {
            if case .failed = holder.phase { true } else { false }
        }
        let (model, _) = try await window()
        panels.name = "Show"
        panels.replace = true

        await model.saveAsTemplate()

        #expect(model.alert == .templateOpen("Show"), "a window with the key and no lock keeps Replace off")
        #expect(try FileManager.default.contentsOfDirectory(atPath: trash.path).isEmpty, "nothing went to the Trash")
        #expect(FileManager.default.contents(atPath: old.appending(path: "session.xml").path) == unreadable)
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

    /// A volume with no swap and no exclusive rename, as exFAT: the claim rename puts the new template at the
    /// name, and the old one goes to the Trash.
    @Test func replaceWithNoSwapPublishesWithTheClaim() async throws {
        defer { clean() }
        _ = try await existing("Show", tracks: 1)
        let (model, _) = try await window()
        app.templatePanels.renames.swap = { _, _ in ENOTSUP }
        app.templatePanels.renames.exclusive = { _, _ in ENOTSUP }
        panels.name = "Show"
        panels.replace = true

        await model.saveAsTemplate()

        #expect(model.alert == nil)
        #expect(try templateTracks("Show") == ["t1", "t2", "t3"], "the name holds the new template")
        #expect(try Session(contentsOf: trash.appending(path: "Show.dirigible")).tracks.map(\.id.rawValue) == ["t1"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: templates.path) == ["Show.dirigible"])
        await model.close()
    }

    /// The claim rename fails too: the new template stays in its folder, and the alert names the Trash and the
    /// path of the new template.
    @Test func aFailedRenameWithNoSwapKeepsTheNewTemplate() async throws {
        defer { clean() }
        _ = try await existing("Show", tracks: 1)
        let (model, _) = try await window()
        app.templatePanels.renames.swap = { _, _ in ENOTSUP }
        app.templatePanels.renames.exclusive = { _, _ in ENOTSUP }
        app.templatePanels.renames.plain = { _, _ in EIO }
        panels.name = "Show"
        panels.replace = true

        await model.saveAsTemplate()

        guard case .templateNewKept(let name, let path) = model.alert else {
            Issue.record("the alert is \(String(describing: model.alert))")
            return await model.close()
        }
        let kept = URL(filePath: path)
        defer { try? FileManager.default.removeItem(at: kept.deletingLastPathComponent()) }
        #expect(name == "Show")
        #expect(kept.lastPathComponent == "Show.dirigible")
        #expect(try Session(contentsOf: kept).tracks.map(\.id.rawValue) == ["t1", "t2", "t3"], "the new one stays")
        #expect(try Session(contentsOf: trash.appending(path: "Show.dirigible")).tracks.map(\.id.rawValue) == ["t1"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: templates.path) == [], "no claim stays")
        await model.close()
    }

    /// The Trash move and the swap back fail: the new template is at the name, and the alert gives the path of
    /// the old one, which stays in its folder.
    @Test func aFailedSwapBackKeepsTheOldTemplate() async throws {
        defer { clean() }
        _ = try await existing("Show", tracks: 1)
        let (model, _) = try await window()
        trashFails.withLock { $0 = true }
        let swaps = OSAllocatedUnfairLock(initialState: 0)
        app.templatePanels.renames.swap = { from, to in
            guard
                swaps.withLock({
                    $0 += 1
                    return $0
                }) == 1
            else { return EIO }
            return renamex_np(from, to, UInt32(RENAME_SWAP)) == 0 ? 0 : errno
        }
        panels.name = "Show"
        panels.replace = true

        await model.saveAsTemplate()

        guard case .templateOldKept(let name, let path) = model.alert else {
            Issue.record("the alert is \(String(describing: model.alert))")
            return await model.close()
        }
        let kept = URL(filePath: path)
        defer { try? FileManager.default.removeItem(at: kept.deletingLastPathComponent()) }
        #expect(name == "Show")
        #expect(try templateTracks("Show") == ["t1", "t2", "t3"], "the name holds the new template")
        #expect(try Session(contentsOf: kept).tracks.map(\.id.rawValue) == ["t1"], "the old one stays")
        await model.close()
    }
}
