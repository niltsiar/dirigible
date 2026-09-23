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
