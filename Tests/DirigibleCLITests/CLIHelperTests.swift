import Foundation
import Testing

@testable import DirigibleAudio
@testable import DirigibleCLI
@testable import DirigibleMCP

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

    /// A3: `dirigible apps` writes one line for each app: the bundle ID, the name with no tab
    /// or line break, and 1 when a process of the app plays.
    @Test func theAppsLinesHaveThreeFields() {
        let apps = [
            RunningApp(
                bundleID: "com.google.Chrome", name: "Google\tChrome", path: "/A", playing: true, processes: [1]),
            RunningApp(bundleID: "us.zoom.xos", name: "zoom\nus", path: "/B", playing: false, processes: [2]),
        ]
        #expect(appLines(apps) == "com.google.Chrome\tGoogle Chrome\t1\nus.zoom.xos\tzoom us\t0\n", "the apps lines")
    }

    /// W2: `dirigible devices` and the `devices` tool write one line for each device: the UID, the
    /// name with no tab or line break, the channels, and the rate, with its fraction when it has one.
    @Test func theDeviceLinesHaveFourFields() throws {
        let devices = try [
            #require(
                InputDevice(
                    uid: "BuiltIn", name: "Mac\tMic\nA", nominalRate: 48_000, availableRates: [48_000...48_000],
                    channelsPerBuffer: [1], latency: 0)),
            #require(
                InputDevice(
                    uid: "USB", name: "Desk", nominalRate: 44_099.5, availableRates: [44_099.5...44_099.5],
                    channelsPerBuffer: [1, 1], latency: 0)),
        ]
        #expect(deviceLines(devices) == "BuiltIn\tMac Mic A\t1\t48000\nUSB\tDesk\t2\t44099.5\n")
        #expect(deviceLines([]).isEmpty && appLines([]).isEmpty, "the command writes no line for an empty list")
    }

    /// A9: one warning line for each silent app track, in arm order. It does not change the exit
    /// code: the track has a clip (row 13:38, "silence line exit code").
    @Test func theSilenceLineNamesTheTrackAndTheApp() {
        #expect(
            silenceWarnings(["t2": "zoom.us", "t1": "Microsoft Teams"], armed: ["t1", "t3", "t2"]) == [
                "track \"t1\" got only silence from Microsoft Teams; check System Audio Recording in Privacy & Security.",
                "track \"t2\" got only silence from zoom.us; check System Audio Recording in Privacy & Security.",
            ], "the silence lines")
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

    /// A child runs in the new temporary folder of its launcher, not in the working folder of the
    /// test process (the repo), so a red test that writes a relative path writes nothing there.
    @Test func aChildRunsInItsOwnTemporaryFolder() async throws {
        let result = try await dirigible(shell: "pwd -P")
        let folder = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        // The launcher deletes its folder before the assert, and Foundation does not resolve a
        // deleted path, so only the expected side goes through realpath: /var is /private/var.
        let temporary = try realPath(FileManager.default.temporaryDirectory.path)
        let working = try realPath(FileManager.default.currentDirectoryPath)
        #expect(result.status == 0)
        #expect(folder.hasPrefix(temporary + "/dirigible-run-"), "the child ran in \(folder)")
        #expect(folder != working)
    }
}

/// The path of `path` with each symbolic link resolved, from `realpath(3)`. The path must exist.
private func realPath(_ path: String) throws -> String {
    guard let resolved = realpath(path, nil) else { throw CocoaError(.fileNoSuchFile) }
    defer { free(resolved) }
    return String(cString: resolved)
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
