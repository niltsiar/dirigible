import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// Remove Unused Files of a take segment (decision 0047, criterion P20 of run
/// 2026-10-28-pre-roll): a plain take whose one segment ends before the playhead finalizes to a
/// pool file with no clip (decision 0004 **Timing**). The prune uses the real Trash: each test
/// removes only the Trash URLs of its report.
@MainActor
struct StudioCapturePruneTests {
    let package: TakePackage
    let names = ["take1-1-1.wav", "Capture/take1-1-1.caf", "Capture/take1-1-1.sidecar"]

    init() throws {
        package = try TakePackage(tracks: [("t1", .mono)])
        try package.segment(
            arm: 1, header: TakePackage.header(firstHost: takeStart - 2_000_000_000),
            samples: sine(seconds: 1, rate: 48_000))
    }

    /// The open finalizes the pending take; the segment is a pool file with no clip.
    func open() async throws -> Studio {
        let studio = try await Studio.open(package.url)
        studio.environment = .test(TestHAL([]))
        try #require(studio.session.files["take1-1-1"]?.capture == "take1-1-1")
        try #require(studio.session.track("t1")?.clips.isEmpty == true)
        return studio
    }

    func bytes(_ path: String) throws -> Int64 {
        let url =
            path.hasPrefix("Capture/")
            ? package.url.appending(path: path) : package.url.appending(path: "Clips/\(path)")
        return try #require(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize).int64
    }

    func cleanUp(_ report: PruneReport?) {
        for moved in report?.moved ?? [] { try? FileManager.default.removeItem(at: moved.trashURL) }
    }

    /// The list has the WAV, the CAF, and the sidecar with their sizes on the disk, and the prune
    /// moves them in the order WAV, CAF, sidecar.
    @Test func pruneMovesTheCaptureFiles() async throws {
        let studio = try await open()
        let sizes = try names.map(bytes)

        let scan = try await studio.unusedFiles()
        #expect(scan.captures == ["take1-1-1"])
        #expect(Set(scan.items.map(\.path)) == Set(names))
        #expect(try scan.items.sorted { $0.path < $1.path }.map(\.bytes) == names.sorted().map(bytes))
        let report = try await studio.removeUnusedFiles(scan)
        defer { cleanUp(report) }

        #expect(report.moved.map(\.item.path) == names && report.failed.isEmpty)
        #expect(report.moved.map(\.item.bytes) == sizes)
        let left = ["take1-1-1.caf", "take1-1-1.sidecar"].filter {
            FileManager.default.fileExists(atPath: package.capture.appending(path: $0).path)
        }
        #expect(left.isEmpty)
        await studio.settle()
    }

    /// P20: after a Stop before the playhead and Remove Unused Files, no segment is unplaced.
    @Test func pruneAfterStopBeforeTKeepsNoUnplacedSegment() async throws {
        let studio = try await open()
        #expect(studio.unplacedSegments.isEmpty)

        let report = try await studio.removeUnusedFiles(try await studio.unusedFiles())
        defer { cleanUp(report) }

        #expect(report.moved.count == 3)
        #expect(studio.session.files["take1-1-1"] == nil)
        #expect(studio.unplacedSegments.isEmpty, "the CAF went with its pool file")
        #expect(segmentsWithAudio(in: package.url).isEmpty, "a new open finds no segment")
        await studio.settle()
    }

    /// A capture ID of `session.xml` that is not a segment stem names no file.
    @Test func aCaptureIDThatIsNotAStemNamesNoFile() {
        #expect(captureFilePaths("take1-1-1") == ["Capture/take1-1-1.caf", "Capture/take1-1-1.sidecar"])
        #expect(captureFilePaths("../Clips/take1-1-1").isEmpty)
        #expect(captureFilePaths("take1-1-1/../../x").isEmpty)
    }
}

extension Int {
    fileprivate var int64: Int64 { Int64(self) }
}
