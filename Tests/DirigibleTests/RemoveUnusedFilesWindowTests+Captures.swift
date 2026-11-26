import AppKit
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio
@testable import DirigibleCore

/// Remove Unused Files of a take segment in the window (criterion P20 of run
/// 2026-10-28-pre-roll): the pool file of the segment (13 bytes) has no clip, and its CAF
/// (11 bytes) and sidecar (3 bytes) are in `Capture/`. A random take number keeps the names of
/// other runs out of the Trash.
extension RemoveUnusedFilesWindowTests {
    /// A key window of the package with the stray WAV (64 bytes) and the segment; and its stem.
    func windowWithSegment() async throws -> (SessionWindow, Studio, NSWindow, String) {
        let package = try await timelinePackage(in: folder.url, tracks: 1, seconds: 1, audio: true)
        try Data(count: 64).write(to: package.appending(path: "Clips/\(stray)"))
        let stem = "take\(Int.random(in: 100_000...999_999_999))-1-1"
        var session = try Session(contentsOf: package)
        try session.addCapture(
            Capture(
                id: CaptureID(stem), deviceUID: "mic", deviceName: "Mic", hostTimeNanos: 1, sampleTime: 0,
                nominalSampleRate: 48_000, measuredSampleRate: 48_000, latency: 0))
        try session.addFile(
            AudioFile(id: FileID(stem), path: "\(stem).wav", layout: .mono, length: 48_000, capture: CaptureID(stem)))
        try session.write(to: package)
        try Data(count: 13).write(to: package.appending(path: "Clips/\(stem).wav"))
        let capture = package.appending(path: "Capture")
        try FileManager.default.createDirectory(at: capture, withIntermediateDirectories: true)
        try Data(count: 11).write(to: capture.appending(path: "\(stem).caf"))
        try Data(count: 3).write(to: capture.appending(path: "\(stem).sidecar"))
        let (model, studio, window, _) = try await openLanes(app, package)
        return (model, studio, window, stem)
    }

    /// The sheet rows hold the CAF and the sidecar with their bytes and the capture reason.
    @Test func sheetListsTheCaptureFiles() async throws {
        let (model, _, window, stem) = try await windowWithSegment()
        _ = try await sheet(model, window)
        let scan = try #require(model.unusedFiles)

        let rows = UnusedFileRow.rows(scan).filter { $0.id.hasPrefix("Capture/") }

        #expect(
            rows == [
                UnusedFileRow(id: "Capture/\(stem).caf", bytes: 11, reason: .sheetUnusedReasonCapture),
                UnusedFileRow(id: "Capture/\(stem).sidecar", bytes: 3, reason: .sheetUnusedReasonCapture),
            ])
        model.unusedFiles = nil
        await model.close()
    }

    /// Move counts the moved capture files in the announcement: the stray, the WAV, the CAF,
    /// and the sidecar.
    @Test func movedAnnouncementCountsTheCaptureFiles() async throws {
        let (model, studio, window, stem) = try await windowWithSegment()
        var posts: [String] = []
        model.chrome?.announce = { text, _ in posts.append(text) }
        let sheet = try await sheet(model, window)
        let move = try #require(buttons(sheet.contentView).first { $0.keyEquivalent == "\r" })

        move.performClick(nil)

        await until(limit: .seconds(10), "the prune ends") { model.pruneReport != nil }
        let report = try #require(model.pruneReport?.report)
        defer { for moved in report.moved { try? FileManager.default.removeItem(at: moved.trashURL) } }
        #expect(
            report.moved.map(\.item.path).filter { $0.hasPrefix("Capture/") } == [
                "Capture/\(stem).caf", "Capture/\(stem).sidecar",
            ])
        #expect(posts.contains(L10n.announceUnusedMoved.format(4, L10n.bytes(91))), "\(posts)")
        #expect(!FileManager.default.fileExists(atPath: studio.url.appending(path: "Capture/\(stem).caf").path))
        await model.close()
    }

    /// A CAF that does not move is in the failed banner, and it stays in `Capture/` with its sidecar.
    @Test func failedCaptureMoveIsNamed() async throws {
        let (model, studio, window, stem) = try await windowWithSegment()
        let sheet = try await sheet(model, window)
        let move = try #require(buttons(sheet.contentView).first { $0.keyEquivalent == "\r" })
        let capture = studio.url.appending(path: "Capture")
        try #require(chmod(capture.path, 0o555) == 0)
        defer { chmod(capture.path, 0o755) }

        move.performClick(nil)

        await until(limit: .seconds(10), "the prune ends") { model.pruneReport != nil }
        let report = try #require(model.pruneReport?.report)
        defer { for moved in report.moved { try? FileManager.default.removeItem(at: moved.trashURL) } }
        let failed = ["Capture/\(stem).caf"]
        #expect(report.failed.map(\.item.path) == failed)
        await until("the banner shows") { model.shown.banners.contains(.unusedFilesFailed(failed)) }
        let banners = ChromeState.reportBanners(model, studio)
        #expect(banners.map(\.key) == ["unusedFilesFailed"], "the moved files have no banner of their own: \(banners)")
        #expect(FileManager.default.fileExists(atPath: capture.appending(path: "\(stem).caf").path))
        #expect(FileManager.default.fileExists(atPath: capture.appending(path: "\(stem).sidecar").path))
        await model.close()
    }
}
