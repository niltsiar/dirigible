import Foundation
import Testing

/// The helper of CLI.swift waits for a child process with no thread of the concurrency pool, and
/// runs at most the bound of its slots. Each hold test has its own slots, so the other suites
/// cannot delay its children.
struct CLIHelperTests {
    /// As many children as the pool is wide wait for a release file. The test writes the file only
    /// after every child started. A helper that holds a pool thread for each child leaves no
    /// thread for this test, so the children end at the limit of the helper.
    @Test func manyChildrenHoldNoPoolThread() async throws {
        let count = ProcessInfo.processInfo.activeProcessorCount
        let statuses = try await holdChildren(count, Slots(bound: count)) { started in
            if try await !poll(until: .now + .seconds(20), { started() == count }) {
                Issue.record("not every child started: \(started()) of \(count)")
            }
        }
        #expect(statuses == Array(repeating: 0, count: count))
    }

    /// Two children more than the bound wait for a release file. The bound starts, and the other
    /// two wait for a slot until the release.
    @Test func theHelperRunsAtMostTheBoundOfChildren() async throws {
        let bound = ProcessInfo.processInfo.activeProcessorCount
        let slots = Slots(bound: bound)
        let statuses = try await holdChildren(bound + 2, slots) { started in
            guard try await poll(until: .now + .seconds(20), { started() >= bound }) else {
                Issue.record("not every slot was taken: \(started()) of \(bound)")
                return
            }
            guard try await poll(until: .now + .seconds(20), { slots.waiting == 2 }) else {
                Issue.record("no child waited for a slot: \(slots.waiting) of 2")
                return
            }
            #expect(slots.peak == bound)
            #expect(started() == bound)
        }
        #expect(statuses == Array(repeating: 0, count: bound + 2))
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

/// Starts `count` children through the helper with `slots`. Each writes its marker file, then
/// waits for the release file. `whileHeld` gets the count of markers; after it, the release file
/// is written. Returns the exit status of each child.
private func holdChildren(
    _ count: Int, _ slots: Slots, whileHeld: (_ started: () -> Int) async throws -> Void
) async throws -> [Int32] {
    let folder = FileManager.default.temporaryDirectory.appending(path: "CLIHelperTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let release = folder.appending(path: "release")
    let script = "touch \"$0\"; while [ ! -e \"$1\" ]; do sleep 0.05; done"

    return try await withThrowingTaskGroup(of: Int32.self) { group in
        for child in 0..<count {
            group.addTask {
                try await dirigible(
                    shell: script, folder.appending(path: "started-\(child)").path, release.path,
                    slots: slots
                )
                .status
            }
        }
        func started() -> Int {
            ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
                .filter { $0.hasPrefix("started-") }.count
        }
        do {
            defer { FileManager.default.createFile(atPath: release.path, contents: nil) }
            try await whileHeld(started)
        }
        return try await group.reduce(into: []) { $0.append($1) }
    }
}

/// Checks `condition` every 10 ms until it is true or `end` passes. Returns the last value.
private func poll(until end: ContinuousClock.Instant, _ condition: () -> Bool) async throws -> Bool {
    while !condition() {
        guard ContinuousClock.now < end else { return false }
        try await Task.sleep(for: .milliseconds(10))
    }
    return true
}
