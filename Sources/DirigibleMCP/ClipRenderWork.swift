import DirigibleAudio
import DirigibleCore
import Foundation

/// The work of a `clip_denoise` or `clip_repair` call after its arguments are checked (decisions 0054,
/// 0049, and 0064). It owns the lines and the texts of `dirigible clip denoise`, `dirigible clip repair`,
/// and the tools. On the files it runs `renderRequest` under the package lock; in the app, `liveJob`
/// runs `Studio.renderClips`.
package struct ClipRenderWork: Sendable {
    let clips: [ClipID]
    let request: ClipRenderRequest
    /// The effect unit to load. Tests set one that does not exist.
    package var component: EffectUnit = .soundIsolation

    package init(clips: [ClipID], request: ClipRenderRequest) {
        (self.clips, self.request) = (clips, request)
    }

    /// The form of a reduction for the command and the tool.
    package static let reductionExpected =
        "an integer from \(NoiseReduction.range.lowerBound) to \(NoiseReduction.range.upperBound)"

    /// The form of a hum for the command and the tool.
    package static let humExpected = "an integer, 50 or 60"

    /// A combination of options that asks for no render, or for a reduction with the noise off.
    package enum Refusal: String, Error {
        case nothingToDo = "Give a hum of 50 or 60 when the noise reduction is off."
        case reductionWithoutNoise = "A reduction needs the noise reduction on."
    }

    /// The one parse of the options of the command and of the tool into a request. The noise is on
    /// unless `noise` is false, and then the request removes a stored noise level; `reduction` is
    /// nil for the standard amount.
    package static func request(noise: Bool, reduction: NoiseReduction?, hum: Hum?) throws(Refusal)
        -> ClipRenderRequest
    {
        if !noise, reduction != nil { throw .reductionWithoutNoise }
        var effects = hum.map { [Effect.hum($0)] } ?? []
        if noise { effects.append(.noise(reduction ?? .standard)) }
        guard let treatment = Treatment(effects) else { throw .nothingToDo }
        return ClipRenderRequest(treatment, removing: noise ? [] : [.noise])
    }

    /// A combination of repair options that asks for no render, or a value outside its range. The
    /// text is the same for the command and for the tool.
    package enum RepairRefusal: Error, Equatable {
        case nothingToDo
        case sibilanceHertzWithoutSibilance
        case rumble
        case clipping
        case sibilance
        case sibilanceHertz

        package var text: String {
            switch self {
            case .nothingToDo: "Give at least one repair: rumble, clipping, or sibilance."
            case .sibilanceHertzWithoutSibilance: "A sibilance frequency needs a sibilance."
            case .rumble: "A rumble is \(ClipRenderWork.integerForm(Rumble.range))."
            case .clipping: "A clipping is \(ClipRenderWork.integerForm(Declip.range))."
            case .sibilance: "A sibilance is \(ClipRenderWork.integerForm(DeEss.decibelRange))."
            case .sibilanceHertz: "A sibilance frequency is \(ClipRenderWork.integerForm(DeEss.hertzRange))."
            }
        }
    }

    /// The form of a whole number in `range`, for the texts and the schema of a repair option.
    package static func integerForm(_ range: ClosedRange<Int>) -> String {
        "an integer from \(range.lowerBound) to \(range.upperBound)"
    }

    /// The one parse of the repair options of the command and of the tool into a request: a nil value
    /// leaves its effect out. The frequency needs a sibilance, and a sibilance with no frequency uses
    /// the standard frequency.
    package static func repairRequest(rumble: Int?, clipping: Int?, sibilance: Int?, sibilanceHertz: Int?)
        throws(RepairRefusal) -> ClipRenderRequest
    {
        var effects: [Effect] = []
        if let clipping {
            guard let declip = Declip(percent: clipping) else { throw .clipping }
            effects.append(.declip(declip))
        }
        if let rumble {
            guard let high = Rumble(hertz: rumble) else { throw .rumble }
            effects.append(.rumble(high))
        }
        if let sibilance {
            let hertz = sibilanceHertz ?? DeEss.standard.hertz
            guard DeEss.decibelRange.contains(sibilance) else { throw .sibilance }
            guard DeEss.hertzRange.contains(hertz) else { throw .sibilanceHertz }
            effects.append(.deess(DeEss(hertz: hertz, decibels: sibilance)!))
        } else if sibilanceHertz != nil {
            throw .sibilanceHertzWithoutSibilance
        }
        guard let treatment = Treatment(effects) else { throw .nothingToDo }
        return ClipRenderRequest(treatment)
    }

    /// The name of this render in the stop text of a long call: the noise reduction when the request
    /// sets or removes the noise, else a repair.
    package var noun: String {
        let noise = request.effects.contains { $0.kind == .noise } || request.removed.contains(.noise)
        return noise ? "noise reduction" : "repair"
    }

    /// One line for each moved clip: the clip and its new file, with a tab between them. No moved
    /// clip: "Nothing to change.", because each clip was unchanged (decision 0057).
    package static func lines(_ clips: [RenderedClip]) -> [String] {
        clips.isEmpty ? ["Nothing to change."] : clips.map { "\($0.clip)\t\($0.file)" }
    }

    /// The render of the files body, in the package that `lock` holds. A cancel read after the
    /// renames removes the new WAVs and changes nothing (decision 0049). `session` changes only on
    /// success, and not for a request that needs no render, so the caller saves nothing then.
    package func render(
        _ session: inout Session, in package: URL, lock: PackageLock, progress: @escaping (Double) -> Void,
        isCancelled: @escaping () -> Bool
    ) throws(ClipRenderError) -> [RenderedClip] {
        let outcome = try renderRequest(
            clips, request: request, of: session, in: package, freeBytes: { lock.freeBytes() },
            component: { _ in component }, progress: progress, isCancelled: isCancelled)
        if isCancelled() {
            removeMadeFiles(outcome.made)
            throw .cancelled
        }
        session = outcome.session
        return outcome.clips
    }

    /// The job of a tool call on the files, under the package lock.
    func run(_ package: URL, path: String, control: CallControl) throws(ToolError) -> String {
        do throws(EditFailure<ClipRenderError>) {
            let (moved, note) = try editPackageCore(package, ripple: false, writeUnchanged: false) {
                session, lock throws(ClipRenderError) in
                try TakeWork.noted(&session, package: package) { session throws(ClipRenderError) -> [RenderedClip] in
                    try render(
                        &session, in: package, lock: lock, progress: { control.report($0) },
                        isCancelled: { control.isCancelled() })
                }
            }
            return (Self.lines(moved) + note).joined(separator: "\n")
        } catch {
            let message =
                switch error {
                case .body(let error): error.message
                case .file(let error): error.message(package: path)
                case .pendingTake: pendingTakeMessage(path)
                case .splitTake: splitTakeMessage(path)
                }
            throw ToolError(message)
        }
    }
}
