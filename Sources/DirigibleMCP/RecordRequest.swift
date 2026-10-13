import DirigibleAudio
import DirigibleCore
import Foundation

/// A take that an agent asks for (decision 0048). The app shows it in a consent sheet; on
/// package files no tool records.
package struct RecordRequest: Sendable, Equatable {
    /// The time that the user has to answer. It and the take start fit in `AgentBridge.replyLimit`.
    package static let answerLimit = Duration.seconds(20)

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

/// The end of one record request in the app (decision 0048). `reply` gives its English text.
package enum RecordAnswer: Equatable, Sendable {
    /// The user clicked Record, and take `take` started on the tracks with these names.
    case started(take: Int, tracks: [String], seconds: Double)
    case declined
    /// The request ended after `RecordRequest.answerLimit` with no answer.
    case noAnswer
    /// Another request waits on the window.
    case waits
    /// The window closed, or changed during the microphone prompt, before the take started.
    case closed
    case minimized
    case busy(AgentBusy)
    /// The request or the start was refused with this error, as `dirigible record` refuses it.
    case refused(StudioError)

    package func reply(package: String) -> AgentReply {
        let text: String
        switch self {
        case .started(let take, let tracks, let seconds):
            let length = seconds.rounded() == seconds ? "\(Int(seconds))" : "\(seconds)"
            return .result(
                text: "Take \(take) records on \(tracks.joined(separator: ", ")) for \(length) s. The user can stop it "
                    + "earlier. Read session_info: the take ended when recording is gone.",
                isError: false)
        case .declined: text = "The user did not record."
        case .noAnswer:
            text =
                "The user did not answer in \(RecordRequest.answerLimit.components.seconds) s. Ask the user to look at "
                + "the Dirigible window, then try again."
        case .waits: text = "A record request for \(package) waits for the user."
        case .closed: text = "The window of \(package) closed before the take started."
        case .minimized: text = "The window of \(package) is minimized. Ask the user to show it, then try again."
        case .busy(let busy): text = busy.message(package: package)
        case .refused(let error): text = error.message(package: package)
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
            + "package must be open in Dirigible, with Let Agents Edit Open Sessions on. No tool records on package files.",
        [seconds, arm, playhead], saves: false
    ) { a throws(ToolError) in
        guard let length = EditRules.takeSeconds(try a[seconds]) else {
            throw ToolError("The seconds must be more than 0 and 86400 (24 h) or less.")
        }
        return .record(
            RecordRequest(
                armed: try a[arm].map { TrackID($0) }, seconds: length, playhead: try a[playhead].map { Frames($0) }))
    }
]
