import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The finalize record of decision 0071 (C18): each conversion of a segment appends the CAF
/// frames, the source rate, and the clip gain to its sidecar, with no flush.
struct FinalizeRecordTests {
    let package: TakePackage
    var sidecarURL: URL { package.capture.appending(path: "take1-1-1.sidecar") }
    static let segment = SegmentName(stem: "take1-1-1")!
    /// The size of one finalize record: length, kind, 24 payload bytes, hash.
    static let recordSize = 4 + 1 + 24 + 4

    /// One 1 s segment at 48 kHz with a float peak of 2.0, so its clip gain is not 0 dB.
    init() throws {
        package = try TakePackage()
        try package.segment(samples: sine(seconds: 1, rate: 48_000).map { $0 * 4 })
    }

    func sidecar() throws -> Sidecar { try #require(try Sidecar.decode(Data(contentsOf: sidecarURL))) }

    func clipGain(_ session: Session) throws -> Gain { try #require(session.track("t1")?.clips.first).gain }

    @Test func aTakeFinalizeAppendsTheRecordOfItsConversion() throws {
        let before = try sidecar()

        let session = try finalizeTake(of: package.read(), in: package.url)

        let gain = try clipGain(session)
        #expect(abs(gain.dB - 6.0206) < 1e-3)
        let after = try sidecar()
        #expect(after.finalized == FinalizeRecord(cafFrames: 48_000, sourceRate: 48_000, conversionGain: gain))
        #expect(after.header == before.header && after.checkpoints == before.checkpoints)
    }

    /// A second finalize appends a second record, and the last one counts.
    @Test func aSecondFinalizeAppendsARecordThatCounts() throws {
        let old = FinalizeRecord(cafFrames: 1, sourceRate: 44_100, conversionGain: .zero)
        #expect(Sidecar.append(old, toSidecarAt: sidecarURL) == nil)
        #expect(try sidecar().finalized == old)
        let size = try Data(contentsOf: sidecarURL).count

        let session = try finalizeTake(of: package.read(), in: package.url)

        #expect(try Data(contentsOf: sidecarURL).count == size + Self.recordSize)
        #expect(
            try sidecar().finalized
                == FinalizeRecord(cafFrames: 48_000, sourceRate: 48_000, conversionGain: try clipGain(session)))
    }

    /// The append first drops a torn tail, which would hide each record after it.
    @Test func anAppendAfterATornRecordDropsTheTornBytes() throws {
        let whole = try Data(contentsOf: sidecarURL)
        try (whole + Sidecar.encode(Checkpoint(fileFrame: 48_000, sampleTime: 0, hostTimeNanos: .max)).prefix(10))
            .write(to: sidecarURL)

        let session = try finalizeTake(of: package.read(), in: package.url)

        let data = try Data(contentsOf: sidecarURL)
        #expect(data.count == whole.count + Self.recordSize)
        #expect(data.prefix(whole.count) == whole)
        #expect(try sidecar().finalized?.conversionGain == clipGain(session))
    }

    @Test func aPlacementFromTheCAFAppendsTheRecord() throws {
        var session = try finalizeTake(of: package.read(), in: package.url)
        let gain = try clipGain(session)
        try session.clear(.zero..<Frames.limit, on: ["t1"])
        try session.removeFile("take1-1-1")
        let size = try Data(contentsOf: sidecarURL).count

        let placed = try placeSegment(Self.segment, to: .fixed(track: "t1", start: 0), of: session, in: package.url)

        guard case .success = placed else {
            Issue.record("the placement failed: \(placed)")
            return
        }
        #expect(try Data(contentsOf: sidecarURL).count == size + Self.recordSize)
        #expect(try sidecar().finalized == FinalizeRecord(cafFrames: 48_000, sourceRate: 48_000, conversionGain: gain))
    }

    /// A sidecar that the finalize cannot write keeps its bytes, and the take still ends.
    @Test func anAppendFaultKeepsNoRecordAndTheTakeEnds() throws {
        let before = try Data(contentsOf: sidecarURL)
        chmod(sidecarURL.path, 0o444)
        defer { chmod(sidecarURL.path, 0o644) }

        let session = try finalizeTake(of: package.read(), in: package.url)

        #expect(session.recording == nil)
        #expect(session.track("t1")?.clips.count == 1)
        let same = try Data(contentsOf: sidecarURL) == before
        #expect(same, "the sidecar bytes do not change")
        #expect(try sidecar().finalized == nil)
    }
}
