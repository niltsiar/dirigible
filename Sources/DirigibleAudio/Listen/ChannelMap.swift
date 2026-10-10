import DirigibleCore

/// The device channels that a listen ring plays left and right (decision 0044). Bit `c - 1` of a
/// mask is device channel `c`, 1 to 64. A mono track plays in both channels, and a stereo track
/// plays its first channel left and its second right. Several tracks sum at unity.
struct ChannelMap: Equatable, Sendable {
    private(set) var left: UInt64 = 0
    private(set) var right: UInt64 = 0

    /// A track with a channel over 64 adds nothing.
    init(routes: [Route.Channels]) {
        for route in routes where route.numbers.allSatisfy({ (1...64).contains($0) }) {
            switch route {
            case .mono(let channel):
                left |= Self.bit(channel)
                right |= Self.bit(channel)
            case .stereo(let first, let second):
                left |= Self.bit(first)
                right |= Self.bit(second)
            }
        }
    }

    init(left: UInt64, right: UInt64) {
        self.left = left
        self.right = right
    }

    private static func bit(_ channel: Int) -> UInt64 { 1 << UInt64(channel - 1) }
}
