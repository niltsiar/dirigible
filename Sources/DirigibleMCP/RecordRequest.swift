import DirigibleAudio
import DirigibleCore
import Foundation

/// A take that an agent asks for (decision 0048). The app shows it in a consent sheet; on
/// package files no tool records.
package struct RecordRequest: Sendable, Equatable {
    /// The time that the user has to answer. It and the take start fit in `AgentBridge.replyLimit`.
    package static let answerLimit = Duration.seconds(20)
    /// The time of a window grant from the click (decision 0050).
    package static let grantLifetime = Duration.seconds(3600)
    /// The take length of all grant takes, and the longest request that can get a grant.
    package static let grantTakeSeconds = 7200.0
    /// The most requests that show a sheet or start a grant take on a window in `askWindow`.
    package static let askLimit = 3
    package static let askWindow = Duration.seconds(60)

    /// The longest take in seconds, 24 h (0041). A take after a click can be this long.
    package static let takeLimit = 86_400.0
    /// A take stops at its length, also while the talk goes on.
    static let lengthRule =
        "For a live talk, ask for a length well past the planned end, for example the plan plus 1 hour: the take "
        + "stops at seconds, and the user ends it earlier with Stop."
    /// A silent app track gives the agent no other sign.
    static let loudnessRule =
        "After a take, run `loudness`: \"none\" for a clip, or a value far below the other tracks (below -50 LUFS), "
        + "means that its track got almost no sound; tell the user."
    /// The rate limit in words: "3 requests in 1 minute".
    package static var askText: String {
        "\(askLimit) requests in \(units(askWindow.components.seconds / 60, "minute"))"
    }

    /// `count` and `unit` in English, with an s after a count other than 1: "1 hour", "2 hours".
    package static func units(_ count: Int64, _ unit: String) -> String { "\(count) \(unit)\(count == 1 ? "" : "s")" }

    /// The tracks of the take, in the order of the request. One or more.
    package let armed: [TrackID]
    /// More than 0 and 86400 (24 h) or less (`EditRules.takeSeconds`).
    package let seconds: Double
    /// The start frame, or nil for the playhead of the window.
    package let playhead: Frames?
    /// The pre-roll in seconds, 1 to 10 (`EditRules.preRollSeconds`), or nil for no pre-roll.
    package let preRoll: Int?

    package init(armed: [TrackID], seconds: Double, playhead: Frames?, preRoll: Int? = nil) {
        (self.armed, self.seconds, self.playhead, self.preRoll) = (armed, seconds, playhead, preRoll)
    }
}

extension EditRules {
    /// The length of a take in seconds: finite, more than 0, and 86400 (24 h) or less.
    package static func takeSeconds(_ seconds: Double) -> Double? {
        seconds.isFinite && seconds > 0 && seconds <= RecordRequest.takeLimit ? seconds : nil
    }

    /// The pre-roll of a timed take in whole seconds (decision 0070): 0 to 10. A take with 0 has no
    /// pre-roll.
    package static func preRollSeconds(_ seconds: Int) -> Int? { (0...10).contains(seconds) ? seconds : nil }
}

/// The window grant after a take start (decision 0050): its end on the wall clock, the take
/// length that it has left, and true when the take started with no sheet.
package struct GrantNote: Equatable, Sendable {
    package let end: Date
    package let secondsLeft: Double
    package let noSheet: Bool

    package init(end: Date, secondsLeft: Double, noSheet: Bool) {
        (self.end, self.secondsLeft, self.noSheet) = (end, secondsLeft, noSheet)
    }

    /// The text of the grant in a reply. The time is HH:MM in the time zone of the Mac.
    var text: String {
        let format = DateFormatter()
        (format.locale, format.dateFormat) = (Locale(identifier: "en_US_POSIX"), "HH:mm")
        return "a window grant of the user covers this connection until \(format.string(from: end)), the window "
            + "close, or a new connection, with \(Int(secondsLeft / 60)) min of takes left. A cancel of a call or a "
            + "new agent session makes a new connection."
    }
}

/// The end of one record request in the app (decision 0048). `reply` gives its English text.
package enum RecordAnswer: Equatable, Sendable {
    /// Take `take` started on the tracks with these names, with `preRoll` seconds of pre-roll or
    /// none, after a click or under a window grant (`grant`, decision 0050).
    case started(take: Int, tracks: [String], seconds: Double, preRoll: Int? = nil, grant: GrantNote? = nil)
    case declined
    /// The request ended after `RecordRequest.answerLimit` with no answer.
    case noAnswer
    /// The call ended before an answer: its bridge closed, or the server stopped.
    case ended
    /// The window closed, or changed during the microphone prompt, before the take started.
    case closed
    case minimized
    case busy(AgentBusy)
    /// The request or the start was refused with this error, as `dirigible record` refuses it.
    case refused(StudioError)
    /// A route of a request track changed after the sheet showed it, or after the grant check.
    case grantChanged
    /// The disk of the package has room for `minutes` of a take on the request tracks, less than
    /// the length (decision 0050).
    case noRoom(minutes: Int)
    /// The window got `RecordRequest.askLimit` requests in the last `askWindow` (decision 0050).
    case tooMany

    package func reply(package: String) -> AgentReply {
        let text: String
        switch self {
        case .started(let take, let tracks, let seconds, let preRoll, let grant):
            let length = seconds.rounded() == seconds ? "\(Int(seconds))" : "\(seconds)"
            let start =
                "Take \(take) records on \(tracks.joined(separator: ", ")) for \(length) s"
                + (preRoll.map { " after a \($0) s pre-roll" } ?? "")
            let lead =
                switch grant {
                case nil: start + ". "
                case let grant? where grant.noSheet: start + " with no sheet: " + grant.text + " "
                case let grant?: start + ". A" + grant.text.dropFirst() + " "
                }
            return .result(
                text: lead + "The user can stop it earlier. Read session_info: the take ended when recording is gone.",
                isError: false)
        case .declined: text = "The user did not record."
        case .noAnswer:
            text =
                "The user did not answer in \(RecordRequest.answerLimit.components.seconds) s. Ask the user to look at "
                + "the Dirigible window, then try again."
        case .ended: text = "The request ended before the user answered: the agent server stopped. Nothing records."
        case .closed: text = "The window of \(package) closed before the take started."
        case .minimized: text = "The window of \(package) is minimized. Ask the user to show it, then try again."
        case .busy(let busy): text = busy.message(package: package)
        // The app asked for the access, so the CLI text that names the terminal is wrong here.
        case .refused(.microphoneAccess):
            text =
                "Dirigible has no microphone access. Ask the user to allow Dirigible in System Settings > "
                + "Privacy & Security > Microphone, then ask again."
        case .refused(let error): text = error.message(package: package)
        case .grantChanged:
            text = "A track route changed during the start. Ask again: the sheet shows."
        case .noRoom(let minutes):
            text = "\(package) has room for \(minutes) min of a take on these tracks. Free disk space, then try again."
        case .tooMany:
            text = "Too many record requests: a window takes \(RecordRequest.askText) at most. Wait, then ask again."
        }
        return .result(text: text, isError: true)
    }
}

/// The refusal of `record` on package files: only the app can ask the user.
func recordOnFilesMessage(_ package: String) -> String {
    "To record, open \(package) in Dirigible and turn on Let Agents Edit Open Sessions in Settings. "
        + "A take needs the consent of the user in the app."
}

extension Kind where T == Double {
    /// A JSON number, not a boolean.
    static let number = Kind(schema: ["type": "number"], expected: "a number") { value in
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }
}

private let seconds = Param.required(
    "seconds", "The length of the take in seconds, 86400 (24 h) or less. " + RecordRequest.lengthRule, .number)
private let arm = Param.required("arm", "The track IDs to record.", .strings(minItems: 1))
private let playhead = Param<Int?>.optional(
    "playhead", "The timeline frame of the take start. The default is the playhead of the window.",
    .integer(minimum: 0))
private let preRoll = Param<Int?>.optional(
    "pre_roll",
    "The seconds of pre-roll, 0 to 10: the session plays from that time before the playhead, and the take starts "
        + "at the playhead. seconds counts from the playhead. The default is 0, no pre-roll.",
    .integer())

let recordTools = [
    Tool(
        "record",
        "Ask the user to record a take. Dirigible shows a consent sheet on the window of the package, and the take "
            + "starts only when the user clicks Record. The call waits \(Int(RecordRequest.answerLimit.components.seconds)) s "
            + "or less for the answer, and gives the take number when the take starts. The take stops after seconds, "
            + "or earlier when the user clicks Stop: read session_info, and the take ended when recording is gone. "
            + RecordRequest.lengthRule + " " + RecordRequest.loudnessRule + " The "
            + "package must be open in Dirigible, with Let Agents Edit Open Sessions on. No tool records on package files. "
            + "A window grant: when the user turns on Don't ask again until I close this window and clicks Record, later "
            + "record calls of the same connection on the same tracks start with no sheet. A grant ends "
            + "\(RecordRequest.units(RecordRequest.grantLifetime.components.seconds / 3600, "hour")) after the click, "
            + "after \(RecordRequest.units(Int64(RecordRequest.grantTakeSeconds / 3600), "hour")) of takes with no "
            + "sheet (the take of the click does not count), at the window close, or at a new connection (a cancel of "
            + "a call or a new agent session). An app track, a record-over, and a length over the grant left always "
            + "show the sheet. A take after a click can be up to "
            + "\(RecordRequest.units(Int64(RecordRequest.takeLimit / 3600), "hour")) long. A window takes "
            + "\(RecordRequest.askText) at most.",
        [seconds, arm, playhead, preRoll], saves: false, batch: .alone
    ) { a throws(ToolError) in
        guard let length = EditRules.takeSeconds(try a[seconds]) else {
            throw ToolError("The seconds must be more than 0 and 86400 (24 h) or less.")
        }
        guard let lead = EditRules.preRollSeconds(try a[preRoll] ?? 0) else {
            throw ToolError("The pre-roll must be 0 to 10 s.")
        }
        return .record(
            RecordRequest(
                armed: try a[arm].map { TrackID($0) }, seconds: length, playhead: try a[playhead].map { Frames($0) },
                preRoll: lead > 0 ? lead : nil))
    }.hinted(.records)
]
