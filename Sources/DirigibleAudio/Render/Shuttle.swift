import DirigibleCore

public struct Shuttle: Hashable, Sendable {
    public enum Direction: Sendable { case forward, reverse }
    public enum Rate: Double, Sendable {
        case half = 0.5
        case one = 1
        case two = 2
        case four = 4
    }
    public var direction: Direction
    public var rate: Rate
    public init(direction: Direction, rate: Rate) {
        self.direction = direction
        self.rate = rate
    }
}

extension Shuttle {
    /// The JKL ladder: the shuttle after `command`, or nil for stopped. L while forward goes up
    /// a rate (4x stays); L while reverse or stopped plays forward at 1x. J mirrors L. A seek keeps
    /// the shuttle.
    public static func after(_ command: TransportCommand, current: Shuttle?) -> Shuttle? {
        switch command {
        case .playStop: current == nil ? Shuttle(direction: .forward, rate: .one) : nil
        case .stopAndReturn, .pause: nil
        case .forward: climb(.forward, from: current)
        case .reverse: climb(.reverse, from: current)
        case .slowForward: Shuttle(direction: .forward, rate: .half)
        case .slowReverse: Shuttle(direction: .reverse, rate: .half)
        case .seek, .speed: current
        }
    }

    private static func climb(_ direction: Direction, from current: Shuttle?) -> Shuttle {
        guard let current, current.direction == direction else { return Shuttle(direction: direction, rate: .one) }
        let next: Rate =
            switch current.rate {
            case .half: .one
            case .one: .two
            case .two, .four: .four
            }
        return Shuttle(direction: direction, rate: next)
    }
}

public enum TransportCommand: Hashable, Sendable {
    case playStop, stopAndReturn, pause, forward, reverse, slowForward, slowReverse
    case seek(Seek)
    /// A vari-speed change: the shuttle stays (decision 0048).
    case speed(SpeedChange)
}

public enum Seek: Hashable, Sendable {
    case start, end, previousClip, nextClip
    case frame(Frames)
}
