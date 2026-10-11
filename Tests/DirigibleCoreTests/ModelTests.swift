import DirigibleCore
import Testing

struct ModelTests {
    enum Tag {}

    @Test func framesAddAndCompare() {
        let start: Frames = 48_000
        let end = start + 96_000
        #expect(end == 144_000)
        #expect(end - start == 96_000)
        #expect((start..<end).contains(100_000))
        #expect(!(start..<end).contains(144_000))
    }

    @Test func gainRefusesValuesThatAreNotFinite() {
        #expect(Gain(dB: .nan) == nil)
        #expect(Gain(dB: .infinity) == nil)
        #expect(Gain(dB: -.infinity) == nil)
        #expect(Gain(dB: -6.5)?.dB == -6.5)
        #expect(Gain.zero.dB == 0)
    }

    /// Track fader C1: every edit path refuses a gain outside -96...+96 dB.
    @Test func theGainRangeRefusesValuesOutside() {
        for dB in [-96, -40, 24, 96.0] { #expect(Gain(dB: dB)?.dB == dB, "C1: \(dB) dB is in the range") }
        for dB in [-96.1, 96.1, 1e300, -1e300] { #expect(Gain(dB: dB) == nil, "C1: \(dB) dB is out of the range") }
        #expect(Gain.range == -96...96)
    }

    /// `Gain(clamping:)` keeps a finite value at the range end and refuses a value that is not finite.
    @Test func clampingKeepsTheRangeEnd() {
        #expect(Gain(clamping: 1e300)?.dB == 96 && Gain(clamping: -200)?.dB == -96 && Gain(clamping: 50)?.dB == 50)
        #expect(Gain(clamping: .infinity) == nil && Gain(clamping: -.infinity) == nil && Gain(clamping: .nan) == nil)
    }

    @Test func layoutComesFromOneOrTwoChannels() {
        #expect(ChannelLayout(channelCount: 1) == .mono)
        #expect(ChannelLayout(channelCount: 2) == .stereo)
        #expect(ChannelLayout(channelCount: 0) == nil)
        #expect(ChannelLayout(channelCount: 3) == nil)
        #expect(ChannelLayout.stereo.channelCount == 2)
    }

    @Test func idsOfOneKindCompareByText() {
        let a: ID<Tag> = "t1"
        #expect(a == ID<Tag>("t1"))
        #expect(a != "t2")
        #expect(ID<Tag>() != ID<Tag>())
    }
}
