import DirigibleCore
import Testing

@testable import DirigibleAudio

/// The JKL ladder of decision 0016 (timeline-playback criterion 7): the next shuttle for each
/// command and each current shuttle. Nil is stopped.
struct ShuttleTests {
    static let fHalf = Shuttle(direction: .forward, rate: .half)
    static let f1 = Shuttle(direction: .forward, rate: .one)
    static let f2 = Shuttle(direction: .forward, rate: .two)
    static let f4 = Shuttle(direction: .forward, rate: .four)
    static let rHalf = Shuttle(direction: .reverse, rate: .half)
    static let r1 = Shuttle(direction: .reverse, rate: .one)
    static let r2 = Shuttle(direction: .reverse, rate: .two)
    static let r4 = Shuttle(direction: .reverse, rate: .four)

    static let table: [(TransportCommand, Shuttle?, Shuttle?)] = [
        (.forward, nil, f1), (.forward, fHalf, f1), (.forward, f1, f2), (.forward, f2, f4), (.forward, f4, f4),
        (.forward, r1, f1), (.forward, r4, f1),
        (.reverse, nil, r1), (.reverse, rHalf, r1), (.reverse, r1, r2), (.reverse, r2, r4), (.reverse, r4, r4),
        (.reverse, f1, r1), (.reverse, f2, r1),
        (.slowForward, nil, fHalf), (.slowForward, f4, fHalf), (.slowForward, r1, fHalf),
        (.slowReverse, nil, rHalf), (.slowReverse, f1, rHalf),
        (.pause, f2, nil), (.pause, nil, nil),
        (.playStop, nil, f1), (.playStop, f2, nil), (.playStop, r1, nil),
        (.stopAndReturn, f1, nil), (.stopAndReturn, nil, nil),
        (.seek(.start), f2, f2), (.seek(.frame(10)), nil, nil), (.seek(.nextClip), rHalf, rHalf),
    ]

    @Test func theLadder() {
        for (command, current, next) in Self.table {
            #expect(Shuttle.after(command, current: current) == next, "\(command) at \(String(describing: current))")
        }
    }
}
