import DirigibleCore
import Foundation
import Testing

/// `dirigible file prune` of a take segment (criterion P20 of run 2026-10-28-pre-roll): the pool
/// file of a segment has no clip, and its CAF (11 bytes) and sidecar (3 bytes) are in `Capture/`.
/// A random take number keeps the names of other runs out of the Trash.
extension FilePruneTests {
    /// Adds the pool file `take<n>-1-1` (13 bytes) of capture `take<n>-1-1`, and its capture files.
    func addSegment() throws -> String {
        let stem = "take\(Int.random(in: 100_000...999_999_999))-1-1"
        try package.edit {
            try $0.addCapture(
                Capture(
                    id: CaptureID(stem), deviceUID: "mic", deviceName: "Mic", hostTimeNanos: 1, sampleTime: 0,
                    nominalSampleRate: 48_000, measuredSampleRate: 48_000, latency: 0))
            try $0.addFile(
                AudioFile(
                    id: FileID(stem), path: "\(stem).wav", layout: .mono, length: 48_000, capture: CaptureID(stem)))
        }
        try Data(count: 13).write(to: clips.appending(path: "\(stem).wav"))
        let capture = package.url.appending(path: "Capture")
        try FileManager.default.createDirectory(at: capture, withIntermediateDirectories: true)
        try Data(count: 11).write(to: capture.appending(path: "\(stem).caf"))
        try Data(count: 3).write(to: capture.appending(path: "\(stem).sidecar"))
        return stem
    }

    func captureExists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: package.url.appending(path: "Capture/\(name)").path)
    }

    /// The dry run lists the CAF and the sidecar with their bytes, and moves nothing.
    @Test func dryRunListsTheCaptureFiles() async throws {
        let stem = try addSegment()

        let result = try await package.run("file", "prune", "PKG", "--dry-run")

        let lines = [
            "Capture/\(stem).caf\t11 bytes", "Capture/\(stem).sidecar\t3 bytes", "\(stem).wav\t13 bytes",
            "\(stray)\t7 bytes", "\(unused)\t5 bytes",
        ]
        .sorted()
        #expect(
            result
                == CLIResult(
                    status: 0,
                    stdout: (lines + ["Unused files: 5 (39 bytes)", "Kept for a backup: 0 (0 bytes)"])
                        .joined(separator: "\n") + "\n", stderr: ""))
        #expect(captureExists("\(stem).caf") && captureExists("\(stem).sidecar"))
    }

    /// The prune moves the WAV, then the CAF, then the sidecar of the segment to the real Trash.
    @Test func pruneMovesTheCaptureFiles() async throws {
        let stem = try addSegment()

        let result = try await package.run("file", "prune", "PKG")

        let moved = result.stdout.split(separator: "\n").map { $0.split(separator: "\t").map(String.init) }
            .filter { $0.count == 3 }
        let trashed = moved.map { URL(filePath: $0[2]) }
        defer { for url in trashed { try? FileManager.default.removeItem(at: url) } }
        #expect(result.status == 0 && result.stderr == "", "\(result)")
        let segment = moved.map(\.[0]).filter { $0.contains(stem) }
        #expect(segment == ["\(stem).wav", "Capture/\(stem).caf", "Capture/\(stem).sidecar"])
        #expect(result.stdout.contains("Moved to the Trash: 5 (39 bytes)."))
        #expect(!captureExists("\(stem).caf") && !captureExists("\(stem).sidecar"))
        #expect(try package.read().files[FileID(stem)] == nil)
    }
}
