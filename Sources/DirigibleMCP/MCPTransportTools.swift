import DirigibleAudio
import DirigibleCore

/// The work of a transport tool: only the app plays (run agent-transport).
enum TransportWork: Hashable, Sendable {
    case play(from: Frames?, to: Frames?)
    case stop
    case locate(Frames)
}

/// The refusal of a transport tool on package files: only the app has a playhead.
func transportOnFilesMessage(_ package: String) -> String {
    "To play, stop, or locate, open \(package) in Dirigible and turn on Let Agents Edit Open Sessions in Settings."
}

/// The refusal of `transport_stop` during a take (decision 0050 Limits).
func transportStopTakeMessage(_ package: String) -> String {
    "\(package) records a take in Dirigible. transport_stop stops only a play; the user stops the take in Dirigible."
}

extension TransportOutcome {
    /// The reply of a transport call, from the outcome only (never from the studio after the call).
    var reply: AgentReply {
        switch self {
        case .state(.stopped(let frame)): .result(text: "Stopped at \(frame.count).", isError: false)
        case .state(.playing(let from, let end, let shuttle)):
            .result(text: "Playing from \(from.count) to \(end.count)\(shuttle.suffix).", isError: false)
        case .pastEnd(let start, let end):
            .result(
                text: "Nothing plays: frame \(start.count) is at or after the end of the play (\(end.count)).",
                isError: true)
        case .superseded:
            .result(
                text: "A later transport command replaced this call. transport_stop gives the state now.",
                isError: true)
        case .failed(let stop): .result(text: "Nothing plays: \(stop.reason).", isError: true)
        }
    }
}

extension Shuttle {
    /// The end of the play text: a period at forward 1x, else the direction and the rate.
    fileprivate var suffix: String {
        guard self != Shuttle(direction: .forward, rate: .one) else { return "" }
        let rate = rate == .half ? "0.5" : String(Int(rate.rawValue))
        return ", \(direction == .forward ? "forward" : "reverse") at \(rate)x"
    }
}

extension PlaybackStop {
    fileprivate var reason: String {
        switch self {
        case .outputUnavailable(let code): "the audio output did not start (error \(code))"
        case .packageUnavailable: "the session package is not available"
        case .noFreeDescriptor(let code): "Dirigible has no free file descriptor (errno \(code))"
        case .outputChanged: "the audio output changed"
        }
    }
}

private let playFrom = Param<Int?>.optional(
    "from", "The timeline frame where the play starts. The default is the playhead of the window.",
    .integer(minimum: 0))
private let playTo = Param<Int?>.optional(
    "to",
    "The timeline frame where the play stops. It must be more than from. The default, and a frame after the end of "
        + "the session, is the end of the session.",
    .integer(minimum: 0))
private let locateAt = Param.required(
    "at", "The timeline frame of the playhead. A frame after the end of the session is allowed.",
    .integer(minimum: 0))

private let appOnly =
    " The package must be open in Dirigible, with Let Agents Edit Open Sessions on. No tool plays on package files. "
    + "The call changes no session and is no undo step. The reply is the state after the call."

/// A timeline frame in `0...Frames.limit`, so no sum of the app can overflow.
private func frame(_ value: Int, _ key: String) throws(ToolError) -> Frames {
    guard value <= Frames.limit.count else {
        throw ToolError("The argument \"\(key)\" must be \(Frames.limit.count) or less.")
    }
    return Frames(value)
}

let transportTools = [
    Tool(
        "transport_play",
        "Play the session in Dirigible, forward at 1x at the speed of the window, from the frame from to the frame "
            + "to. With neither, the play starts at the playhead and runs to the end of the session. The play stops "
            + "at to. During a play, the call starts a new play. A call during a take, or while Dirigible is busy, gives an error "
            + "and plays nothing." + appOnly,
        [playFrom, playTo], saves: false
    ) { a throws(ToolError) in
        let from = try a[playFrom].map { value throws(ToolError) in try frame(value, "from") }
        let to = try a[playTo].map { value throws(ToolError) in try frame(value, "to") }
        if let from, let to, to <= from { throw ToolError("to must be more than from.") }
        return .transport(.play(from: from, to: to))
    },
    Tool(
        "transport_stop",
        "Stop the play in Dirigible. With nothing playing, the call changes nothing and gives the playhead. It "
            + "never stops a take: during a take it gives an error, and the user stops the take in Dirigible."
            + appOnly,
        [], saves: false
    ) { _ throws(ToolError) in .transport(.stop) },
    Tool(
        "transport_locate",
        "Move the playhead in Dirigible to at, as a click in the ruler does. Stopped, the playhead moves and the next "
            + "take starts there. During a play, the play goes on from at; an at after the end of the session stops "
            + "the play there." + appOnly,
        [locateAt], saves: false
    ) { a throws(ToolError) in .transport(.locate(try frame(a[locateAt], "at"))) },
]
