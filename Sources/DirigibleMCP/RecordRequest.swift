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

    /// The tracks of the take, in the order of the request. One or more.
    package let armed: [TrackID]
    /// More than 0 and 86400 (24 h) or less (`EditRules.takeSeconds`).
    package let seconds: Double
    /// The start frame, or nil for the playhead of the window.
    package let playhead: Frames?

    package init(armed: [TrackID], seconds: Double, playhead: Frames?) {
        (self.armed, self.seconds, self.playhead) = (armed, seconds, playhead)
    }
}

extension EditRules {
    /// The length of a take in seconds: finite, more than 0, and 86400 (24 h) or less.
    package static func takeSeconds(_ seconds: Double) -> Double? {
        seconds.isFinite && seconds > 0 && seconds <= 86_400 ? seconds : nil
    }
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
    /// Take `take` started on the tracks with these names, after a click or under a window grant
    /// (`grant`, decision 0050).
    case started(take: Int, tracks: [String], seconds: Double, grant: GrantNote? = nil)
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
        case .started(let take, let tracks, let seconds, let grant):
            let length = seconds.rounded() == seconds ? "\(Int(seconds))" : "\(seconds)"
            let start = "Take \(take) records on \(tracks.joined(separator: ", ")) for \(length) s"
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
        case .refused(let error): text = error.message(package: package)
        case .grantChanged:
            text = "A track route changed during the start. Ask again: the sheet shows."
        case .noRoom(let minutes):
            text = "\(package) has room for \(minutes) min of a take on these tracks. Free disk space, then try again."
        case .tooMany:
            let (limit, window) = (RecordRequest.askLimit, RecordRequest.askWindow.components.seconds)
            text = "Too many record requests: \(limit) in \(window) s. Wait, then ask again."
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

private let seconds = Param.required("seconds", "The length of the take in seconds, 86400 (24 h) or less.", .number)
private let arm = Param.required("arm", "The track IDs to record.", .strings(minItems: 1))
private let playhead = Param<Int?>.optional(
    "playhead", "The timeline frame of the take start. The default is the playhead of the window.",
    .integer(minimum: 0))

let recordTools = [
    Tool(
        "record",
        "Ask the user to record a take. Dirigible shows a consent sheet on the window of the package, and the take "
            + "starts only when the user clicks Record. The call waits \(Int(RecordRequest.answerLimit.components.seconds)) s "
            + "or less for the answer, and gives the take number when the take starts. The take stops after seconds, "
            + "or earlier when the user clicks Stop: read session_info, and the take ended when recording is gone. The "
            + "package must be open in Dirigible, with Let Agents Edit Open Sessions on. No tool records on package files. "
            + "A window grant: when the user turns on Don't ask again until I close this window and clicks Record, later "
            + "record calls of the same connection on the same tracks start with no sheet. A grant ends after "
            + "\(RecordRequest.grantLifetime.components.seconds / 3600) h, after "
            + "\(Int(RecordRequest.grantTakeSeconds / 3600)) h of takes, at the window close, or at a new connection (a "
            + "cancel of a call or a new agent session). An app track, a record-over, and a length over the grant left "
            + "always show the sheet. A window takes \(RecordRequest.askLimit) requests in "
            + "\(RecordRequest.askWindow.components.seconds) s at most.",
        [seconds, arm, playhead], saves: false
    ) { a throws(ToolError) in
        guard let length = EditRules.takeSeconds(try a[seconds]) else {
            throw ToolError("The seconds must be more than 0 and 86400 (24 h) or less.")
        }
        return .record(
            RecordRequest(
                armed: try a[arm].map { TrackID($0) }, seconds: length, playhead: try a[playhead].map { Frames($0) }))
    }.hinted(.records)
]
