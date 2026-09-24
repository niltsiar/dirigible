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
