import Foundation
import Testing

/// The helper of CLI.swift waits for a child process with no thread of the concurrency pool.
struct CLIHelperTests {
    /// Two children for each pool thread wait for a release file. The test writes the file only
    /// after every child started. A helper that holds a pool thread for each child leaves no
    /// thread for this test, so the children end at the limit of the helper.
    @Test func manyChildrenHoldNoPoolThread() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "CLIHelperTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let count = 2 * ProcessInfo.processInfo.activeProcessorCount
        let release = folder.appending(path: "release")
        let script = "touch \"$0\"; while [ ! -e \"$1\" ]; do sleep 0.05; done"

        let statuses = try await withThrowingTaskGroup(of: Int32.self) { group in
            for child in 0..<count {
                group.addTask {
                    try await dirigible(shell: script, folder.appending(path: "started-\(child)").path, release.path)
                        .status
                }
            }
            func started() -> Int {
                ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
                    .filter { $0.hasPrefix("started-") }.count
            }
            let end = ContinuousClock.now + .seconds(20)
            while started() < count {
                guard ContinuousClock.now < end else {
                    Issue.record("not every child started: \(started()) of \(count)")
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            FileManager.default.createFile(atPath: release.path, contents: nil)
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(statuses == Array(repeating: 0, count: count))
    }

    /// A child that exits before the helper waits still wakes the helper: a lost wake-up would
    /// hang the run.
    @Test func aChildThatExitsAtOnceWakesTheHelper() async throws {
        var wrong = 0
        for _ in 0..<200 {
            if try await dirigible(shell: "exit 3").status != 3 { wrong += 1 }
        }
        #expect(wrong == 0)
    }
}
