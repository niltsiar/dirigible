import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The leave mode of decision 0021 (criteria 6, 14 to 16): a take that an unreadable segment keeps
/// pending ends without that segment only when the user asks for it. The segment stays unplaced,
/// and a placement puts it at its recorded time when it reads again.
///
/// Fixture, made off the main actor: a pending two-arm take 1 (playhead 96,000, first frame 10 ms
/// after the take start, latency 48) with a closed 2.0 s segment on each arm. Each test restores
/// the file modes in a `defer`, so `TemporaryFolder` can remove the files.
struct LeaveUnreadableTests {
    let package: TakePackage
    static let segment = SegmentName(stem: "take1-1-1")!

    init() throws {
        package = try TakePackage(tracks: [("t1", .mono), ("t2", .mono)])
        try package.segment(arm: 1, samples: sine(seconds: 2, rate: 48_000))
        try package.segment(arm: 2, samples: sine(seconds: 2, rate: 48_000, frequency: 500))
    }

    func file(_ name: String) -> URL { package.capture.appending(path: name) }

    /// The names and sizes of the files in `Capture/`, without the take anchor.
    func captureListing() throws -> [String: Int] {
        var result: [String: Int] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: package.capture.path)
        where name != "take1.anchor" {
            let attributes = try FileManager.default.attributesOfItem(atPath: file(name).path)
            result[name] = (attributes[.size] as? NSNumber)?.intValue ?? -1
        }
        return result
    }

    // MARK: Criterion 14

    @Test @MainActor func aStrictFinalizeKeepsTheTakePending() async throws {
        let caf = file("take1-1-1.caf")
        chmod(caf.path, 0o000)
        defer { chmod(caf.path, 0o644) }
        let unreadable = StudioError.finalize(
            .segmentUnreadable(Self.segment, file: "Capture/take1-1-1.caf", errno: EACCES))

        let studio = try await Studio.open(package.url)

        #expect(studio.pendingTake?.take == 1)
        #expect(studio.takeError == unreadable)
        await #expect(throws: unreadable) { try await studio.retryFinalize() }
        #expect(studio.pendingTake?.take == 1)
        #expect(studio.session.track("t2")?.clips.isEmpty == true)
        #expect(try package.read().recording?.take == 1)
    }

    // MARK: Criterion 15

    enum Unreadable: String, CaseIterable, CustomTestStringConvertible {
        case caf, sidecar
        var testDescription: String { rawValue }
    }

    @Test(arguments: Unreadable.allCases)
    @MainActor func theLeaveModeEndsTheTakeWithoutTheUnreadableSegment(unreadable: Unreadable) async throws {
        let path = file("take1-1-1.\(unreadable.rawValue)")
        chmod(path.path, 0o000)
        defer { chmod(path.path, 0o644) }
        let capture = try captureListing()
        let studio = try await Studio.open(package.url)
        #expect(
            studio.takeError
                == .finalize(
                    .segmentUnreadable(Self.segment, file: "Capture/take1-1-1.\(unreadable.rawValue)", errno: EACCES)))

        try await studio.retryFinalize(leavingUnreadable: true)

        #expect(studio.pendingTake == nil)
        #expect(studio.takeError == nil)
        #expect(studio.session.track("t1")?.clips.isEmpty == true)
        #expect(studio.session.track("t2")?.clips.map(\.id) == ["take1-2-1"])
        #expect(studio.unplacedSegments == [Self.segment])
        #expect(try package.read() == studio.session, "the end of the take is saved")
        #expect(try TakeAnchor.read(take: 1, in: package.url)?.get().armedTracks == ["t1", "t2"])
        // Criterion 24, amended by decision 0071: the sidecar of the converted segment gets one
        // finalize record, and no other file in Capture/ changes.
        var expected = capture
        expected["take1-2-1.sidecar"]? += 33
        #expect(try captureListing() == expected, "no file in Capture/ is deleted or changed (criterion 24)")
    }

    // MARK: Criterion 16

    enum TakeWide: String, CaseIterable, CustomTestStringConvertible {
        case readOnlyClips, removedCAF
        var testDescription: String { rawValue }
    }

    /// With the leave mode on, a fault that can go away still throws, so the take stays pending.
    /// Each row is a negative control of the catch clause of the leave mode.
    @Test(arguments: TakeWide.allCases)
    func takeWideFaultsStayTakeWide(fault: TakeWide) throws {
        let clips = package.url.appending(path: "Clips")
        try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
        defer { chmod(clips.path, 0o755) }
        let second = file("take1-2-1.caf")
        var readFault: ReadFault?
        switch fault {
        case .readOnlyClips:
            chmod(clips.path, 0o500)
        case .removedCAF:
            readFault = ReadFault(stem: "take1-1-1", block: 0) { _ = unlink(second.path) }
        }

        let error = #expect(throws: FinalizeError.self) {
            try finalizeTake(of: package.read(), in: package.url, leavingUnreadable: true, readFault: readFault)
        }

        switch (fault, error) {
        case (.readOnlyClips, .writeFailed(file: "Clips/take1-1-1.wav", _)?): break
        case (.removedCAF, .readFailed(file: "Capture/take1-2-1.caf", errno: ENOENT)?): break
        default: Issue.record("\(fault): unexpected error \(String(describing: error))")
        }
        #expect(!FileManager.default.fileExists(atPath: file("take1.anchor").path), "the take has no anchor")
    }

    // MARK: Criterion 6

    /// The segment that the leave mode left unplaced, readable again, goes to the clip that a
    /// strict finalize of the same package gives (`PlaceSegmentTests.recorded`).
    @Test @MainActor func aSegmentLeftUnreadableIsPlacedAtItsRecordedTime() async throws {
        let caf = file("take1-1-1.caf")
        chmod(caf.path, 0o000)
        defer { chmod(caf.path, 0o644) }
        let studio = try await Studio.open(package.url)
        try await studio.retryFinalize(leavingUnreadable: true)
        try #require(studio.unplacedSegments == [Self.segment])
        chmod(caf.path, 0o644)

        _ = try await studio.place(Self.segment)

        #expect(studio.session.track("t1")?.clips.map { $0 } == [PlaceSegmentTests.recorded])
        #expect(studio.unplacedSegments == [])
    }
}
