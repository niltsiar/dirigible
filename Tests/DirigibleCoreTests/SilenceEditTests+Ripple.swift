import Foundation
import Testing

@testable import DirigibleCore

/// When a silence plan is a ripple (decisions 0037 and 0066).
extension SilenceEditTests {
    /// A plan counts as a ripple only when a cut removes frames: a silence of `keep` frames or less
    /// cuts nothing. Fail value: a shorten of 24 000 frames with a keep of 24 000 counts as a ripple.
    @Test func aPlanRipplesOnlyWhenACutRemovesFrames() throws {
        let short = 96_000..<120_000 as Range<Frames>
        let long = 96_000..<120_001 as Range<Frames>
        #expect(try Self.plan([(short, .shorten)]).removesFrames(sampleRate: 48_000) == false)
        #expect(try Self.plan([(long, .shorten)]).removesFrames(sampleRate: 48_000))
        let others = try Self.plan([(long, .mute), (Self.silenceB, .mark(name: "Silence 1"))])
        #expect(others.removesFrames(sampleRate: 48_000) == false)
        let mixed = try Self.plan([(short, .shorten), (Self.silenceB, .mute)])
        #expect(mixed.removesFrames(sampleRate: 48_000) == false)
        let two = try Self.plan([(short, .shorten), (Self.silenceB, .shorten)])
        #expect(two.removesFrames(sampleRate: 48_000))
    }

    /// A nil keep is half a second, so the same silence cuts at 48 kHz and not at 96 kHz.
    @Test func aNilKeepFollowsTheRateOfTheSession() throws {
        let plan = try Self.plan([(0..<30_000, .shorten)], keep: nil)
        #expect(plan.removesFrames(sampleRate: 48_000))
        #expect(plan.removesFrames(sampleRate: 96_000) == false)
        #expect(try Self.plan([(0..<24_000, .shorten)], keep: nil).removesFrames(sampleRate: 48_000) == false)
    }
}
