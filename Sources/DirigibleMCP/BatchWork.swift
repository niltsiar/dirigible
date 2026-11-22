import DirigibleAudio
import DirigibleCore
import Foundation

/// The work of the tool `batch` (decision 0063): many edit calls as one edit. In the app the steps
/// run in one `Studio.edit`, and on the files in one `editPackageCore`, so a failure at any step
/// changes nothing. A step is a pure edit of the session value: it has no package and no lock.
package struct BatchWork: Sendable {
    /// The count of calls in a batch.
    package static let limit = 1...20

    /// One item of `calls`: the tool name and the JSON bytes of its arguments object.
    package struct Call: Sendable {
        let tool: String
        let arguments: Data
    }

    /// Why one step changed nothing.
    package enum StepError: Error {
        case session(SessionError)
        case marker(MarkerEditError)

        var message: String {
            switch self {
            case .session(let error): error.message
            case .marker(let error): error.message
            }
        }
    }

    struct Step: Sendable {
        let tool: String
        let ripple: RippleNeed
        let edit: @Sendable (inout Session) throws(StepError) -> [String]
    }

    /// A call that the check refused, by index and tool: no step ran.
    package struct CheckFailure: Error {
        package let index: Int
        package let tool: String
        package let error: ToolError

        package var message: String { failureLine(index: index, tool: tool, error.message) }
    }

    /// The step that failed in the run, by index and tool, and why. A busy studio and a pending
    /// take on the files have no index, so they are not a `Failure`.
    package struct Failure: Error {
        package enum Cause {
            case step(StepError)
            case rippleBlocked
        }

        package let index: Int
        package let tool: String
        package let cause: Cause

        /// `rippleBlocked` is the split-take text of the path: it differs for the app and the files.
        package func message(rippleBlocked: String) -> String {
            let text =
                switch cause {
                case .step(let error): error.message
                case .rippleBlocked: rippleBlocked
                }
            return failureLine(index: index, tool: tool, text)
        }
    }

    /// The one failure line of a call, for a check failure and a step failure (decision 0063).
    private static func failureLine(index: Int, tool: String, _ text: String) -> String {
        "calls[\(index)] \(tool) failed, so the batch changed nothing: \(text)"
    }

    let steps: [Step]

    /// The one Kind of `calls`: an array of 1 to 20 items. An item that is not a call is nil here,
    /// so `calls(of:)` can name its index.
    static let calls = Kind<[Call?]>(
        schema: [
            "type": "array", "items": callSchema, "minItems": limit.lowerBound, "maxItems": limit.upperBound,
        ],
        expected: "an array of \(limit.lowerBound) to \(limit.upperBound) calls"
    ) { value in
        guard let items = value as? [Any], limit.contains(items.count) else { return nil }
        return items.map(call(of:))
    }

    /// The call of one item, as the item schema says. A JSON null counts as absent.
    private static func call(of item: Any) -> Call? {
        guard let object = item as? [String: Any], let tool = object["tool"] as? String,
            let arguments = object["arguments"] as? [String: Any],
            object.allSatisfy({ ["tool", "arguments"].contains($0.key) || $0.value is NSNull }),
            let data = try? JSONSerialization.data(withJSONObject: arguments)
        else { return nil }
        return Call(tool: tool, arguments: data)
    }

    /// The calls of a parsed `calls` value. The first item that is not a call is refused by its index.
    package static func calls(of items: [Call?]) throws(ToolError) -> [Call] {
        var calls: [Call] = []
        for (index, item) in items.enumerated() {
            guard let item else {
                throw ToolError(#"calls[\#(index)]: an item must be {"tool": <name>, "arguments": {...}}."#)
            }
            calls.append(item)
        }
        return calls
    }

    private static var callSchema: Schema {
        let tool: Schema = ["type": "string", "description": "The name of the tool."]
        let arguments: Schema = [
            "type": "object", "description": "The arguments of the tool, with no package.",
        ]
        let properties: [String: Schema] = ["tool": tool, "arguments": arguments]
        return [
            "type": "object", "properties": properties, "required": ["tool", "arguments"],
            "additionalProperties": false,
        ]
    }

    /// `calls` as `batch` and `dirigible batch` read it, with the one Kind, so both give one text.
    package static func parse(_ value: Any) throws(ToolError) -> [Call] {
        try calls(of: DirigibleMCP.parse(value, "calls", calls))
    }

    /// Checks the calls in order. An unknown tool, an inner `package`, a tool with the role `.alone`,
    /// and a call that copies a file are refused before any step runs. A `.step` tool runs its make
    /// with the package of the batch; its work is a step when it is an edit of the session value.
    package static func check(_ calls: [Call], package: String) throws(CheckFailure) -> BatchWork {
        var steps: [Step] = []
        for (index, call) in calls.enumerated() {
            do throws(ToolError) {
                steps.append(try step(call, package: package))
            } catch {
                throw CheckFailure(index: index, tool: call.tool, error: error)
            }
        }
        return BatchWork(steps: steps)
    }

    private static func step(_ call: Call, package: String) throws(ToolError) -> Step {
        guard let tool = Tool.all.first(where: { $0.name == call.tool }) else {
            throw ToolError("no tool \(call.tool).")
        }
        guard tool.batch == .step, case .package(let params, let make) = tool.body else {
            throw tool.name == "batch" ? ToolError("a batch cannot hold a batch.") : notAStep(tool.name)
        }
        guard var json = (try? JSONSerialization.jsonObject(with: call.arguments)) as? [String: Any] else {
            throw ToolError("The argument \"arguments\" must be an object.")
        }
        if let inner = json["package"], !(inner is NSNull) {
            throw ToolError("The argument \"package\" belongs to the batch, not to a call.")
        }
        json["package"] = package
        let work = try make(try Arguments(json, params: params))
        switch work {
        case .edit(let ripple, let edit):
            return Step(tool: tool.name, ripple: ripple) { session throws(StepError) in
                do throws(SessionError) {
                    let ids = try edit(&session)
                    return ids.isEmpty ? ["OK"] : ids
                } catch {
                    throw .session(error)
                }
            }
        case .marker(let marker):
            if let image = marker.image, !image.isEmpty { throw notAStep(tool.name) }
            return Step(tool: tool.name, ripple: false) { session throws(StepError) in
                do throws(MarkerEditError) { return [try marker.edit(&session).rawValue] } catch {
                    throw .marker(error)
                }
            }
        case .episode(let episode):
            if let artwork = episode.artwork, !artwork.isEmpty { throw notAStep(tool.name) }
            return Step(tool: tool.name, ripple: false) { session throws(StepError) in
                episode.edit(&session)
                return ["OK"]
            }
        case .takeImport, .info, .create, .paste, .backups, .revert, .episodeInfo, .words, .prune, .record,
            .transport, .loudness, .export, .stems, .level, .duck, .ride, .sync, .matchVoice, .importFile, .splitStereo,
            .importSession, .clipRender,
            .chapters,
            .transcriptExport, .takeMap, .read, .transcribe, .batch:
            throw notAStep(tool.name)
        }
    }

    private static func notAStep(_ tool: String) -> ToolError {
        ToolError("\(tool) cannot run in a batch: a step is an edit of session.xml only.")
    }

    /// Runs the steps in order on `session`. Before a ripple step it asks `canRipple` of the
    /// working copy, so a step that splits a take blocks a later ripple (decision 0037).
    func run(_ session: inout Session, canRipple: (Session) -> Bool) throws(Failure) -> [[String]] {
        var results: [[String]] = []
        for (index, step) in steps.enumerated() {
            if step.ripple.isNeeded(session), !canRipple(session) {
                throw Failure(index: index, tool: step.tool, cause: .rippleBlocked)
            }
            do throws(StepError) {
                results.append(try step.edit(&session))
            } catch {
                throw Failure(index: index, tool: step.tool, cause: .step(error))
            }
        }
        return results
    }

    /// `calls[<i>] <tool>: <line>` for each result line of each step.
    func lines(_ results: [[String]]) -> [String] {
        var lines: [String] = []
        for (index, (step, result)) in zip(steps, results).enumerated() {
            lines += result.map { "calls[\(index)] \(step.tool): \($0)" }
        }
        return lines
    }

    /// The one files entry, for the tool and the command: one `editPackageCore`, the steps, and the
    /// take sync note once. The result lines on success. `scan` gives the ripple rule of the package,
    /// once under the lock: a step cannot change `Capture/`.
    package func runOnFiles(
        _ package: URL, log: () -> DiagnosticLog, scan: (URL) -> (Session) -> Bool = rippleBlocked(in:)
    ) throws(EditFailure<Failure>) -> [String] {
        let (results, note) = try editPackageCore(package, ripple: false, log: log) { session, _ throws(Failure) in
            let blocked = steps.contains { $0.ripple.isNeeded(session) } ? scan(package) : { _ in false }
            return try TakeWork.noted(&session, package: package) { session throws(Failure) in
                try run(&session, canRipple: { !blocked($0) })
            }
        }
        return lines(results) + note
    }
}
