import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The finalize fault rule of decision 0012 (criteria 19, 20, 21): a fault of one segment leaves
/// that segment unplaced and the take ends; only a fault that can go away throws.
struct FinalizeFaultTests {
    let package: TakePackage

    /// A take with two tracks, `t1` and `t2`, and a 2.0 s segment on each.
    init() throws {
        package = try TakePackage(tracks: [("t1", .mono), ("t2", .mono)])
        try package.segment(arm: 1, samples: sine(seconds: 2, rate: 48_000))
        try package.segment(arm: 2, samples: sine(seconds: 2, rate: 48_000, frequency: 500))
    }

    func file(_ name: String) -> URL { package.capture.appending(path: name) }

    enum Fault: String, CaseIterable, CustomTestStringConvertible {
        case badMagic, randomCAF, rateNotTheHeaderRate, clipIDInUse
        var testDescription: String { rawValue }
    }

    func apply(_ fault: Fault) throws {
        switch fault {
        case .badMagic:
            let handle = try FileHandle(forWritingTo: file("take1-1-1.sidecar"))
            try handle.write(contentsOf: Data("XXXXXXXX".utf8))
            try handle.close()
        case .randomCAF:
            var random = SeededGenerator(seed: 7)
            try Data((0..<10_000).map { _ in UInt8.random(in: 0...255, using: &random) }).write(
                to: file("take1-1-1.caf"))
        case .rateNotTheHeaderRate:
            // The CAF is at 44.1 kHz; the sidecar says 48 kHz.
            let sidecar = try Data(contentsOf: file("take1-1-1.sidecar"))
            try package.segment(
                arm: 1, header: TakePackage.header(rate: 44_100), samples: sine(seconds: 2, rate: 44_100))
            try sidecar.write(to: file("take1-1-1.sidecar"))
        case .clipIDInUse:
            var session = try package.read()
            try session.addFile(AudioFile(id: "user", path: "user.wav", layout: .mono, length: 1_000))
            try session.place(Clip(id: "take1-1-1", file: "user", start: 0, offset: 0, length: 1_000), on: "t2")
            try session.write(to: package.url)
        }
    }

    @Test(arguments: Fault.allCases)
    func aFaultOfOneSegmentLeavesItUnplacedAndPlacesTheOther(fault: Fault) throws {
        try apply(fault)

        let session = try finalizeTake(of: package.read(), in: package.url)

        #expect(session.recording == nil)
        #expect(session.track("t2")?.clips.contains { $0.id == "take1-2-1" } == true)
        #expect(session.captures["take1-1-1"] == nil)
        #expect(session.files["take1-1-1"] == nil)
        #expect(session.track("t1")?.clips.isEmpty == true)
        #expect(unplacedSegments(in: package.url, session: session) == ["take1-1-1"])
    }

    @Test func withNoFaultBothSegmentsArePlaced() throws {
        let session = try finalizeTake(of: package.read(), in: package.url)

        #expect(session.track("t1")?.clips.map(\.id) == ["take1-1-1"])
        #expect(session.track("t2")?.clips.map(\.id) == ["take1-2-1"])
        #expect(unplacedSegments(in: package.url, session: session) == [])
    }

    @Test func aCAFThatDoesNotOpenThrowsAndPlacesNothing() throws {
        chmod(file("take1-1-1.caf").path, 0o000)
        defer { chmod(file("take1-1-1.caf").path, 0o644) }

        #expect(throws: FinalizeError.readFailed(file: "Capture/take1-1-1.caf", errno: EACCES)) {
            try finalizeTake(of: package.read(), in: package.url)
        }
    }

    @Test func aClipsFolderThatIsReadOnlyThrows() throws {
        let clips = package.url.appending(path: "Clips")
        chmod(clips.path, 0o500)
        defer { chmod(clips.path, 0o755) }

        let error = #expect(throws: FinalizeError.self) { try finalizeTake(of: package.read(), in: package.url) }
        guard case .writeFailed(let file, _) = error else {
            Issue.record("Expected writeFailed, got \(String(describing: error))")
            return
        }
        #expect(file == "Clips/take1-1-1.wav")
    }

    @Test func anErrnoInTheMiddleOfACAFReadThrows() throws {
        let fault = ReadFault(stem: "take1-1-1", block: 1, errno: EIO)

        #expect(throws: FinalizeError.readFailed(file: "Capture/take1-1-1.caf", errno: EIO)) {
            try finalizeTake(of: package.read(), in: package.url, readFault: fault)
        }
    }

    @Test func unplacedSegmentsSkipEmptyPlacedAndPendingCAFs() throws {
        let pending = try package.read()
        #expect(unplacedSegments(in: package.url, session: pending) == [], "the pending take is not listed")

        let session = try finalizeTake(of: pending, in: package.url)
        #expect(unplacedSegments(in: package.url, session: session) == [], "placed segments are not listed")

        try package.segment(take: 2, samples: [], checkpoints: [])
        try package.segment(take: 3, samples: sine(seconds: 0.1, rate: 48_000))
        #expect(unplacedSegments(in: package.url, session: session) == ["take3-1-1"])
    }
}
