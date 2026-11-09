import DirigibleAudio
import DirigibleCore
import Foundation

/// The work of a `clip_level_over_time` call or command after its arguments are checked (decisions
/// 0049 and 0064). It is the one owner of the argument rules, the steps on the files, and the lines
/// of `dirigible clip level-over-time` and the tool. In the app, `liveJob` runs
/// `Studio.levelOverTime` and `Studio.removeLevelOverTime`.
package struct RideWork: Sendable {
    let clips: [ClipID]
    let clear: Bool
    let range: Range<Frames>?

    /// Checks the arguments: the text of a refusal, for exit 64 or a tool error. At least one clip.
    /// `from` and `to` come together, with `from < to`, as frames in 0...2^40, and only with `clear`.
    package static func parse(clips: [String], clear: Bool, from: Int?, to: Int?) -> Result<RideWork, ToolError> {
        guard !clips.isEmpty else { return .failure(ToolError("Give one or more clips.")) }
        var range: Range<Frames>?
        switch (from, to) {
        case (nil, nil): range = nil
        case (let from?, let to?)
        where (0...Frames.limit.count).contains(from) && (0...Frames.limit.count).contains(to) && from < to:
            range = Frames(from)..<Frames(to)
        default: return .failure(ToolError("from and to come together, as frames in 0...2^40 with from < to."))
        }
        if range != nil, !clear { return .failure(ToolError("from and to need clear.")) }
        return .success(RideWork(clips: clips.map { ClipID($0) }, clear: clear, range: range))
    }

    /// The ride, or the remove, in `session`: one stdout line for each named clip. A read fault, a
    /// refusal, or a cancel keeps `session` as it was. The flag is read last before the caller saves.
    package func run(
        _ session: inout Session, package: URL, progress: @escaping @Sendable (Double) -> Void = { _ in },
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) throws(StudioError) -> [String] {
        var ridden = session
        if clear {
            let changed: [ClipID]
            do throws(SessionError) {
                changed = try ridden.removeRides(Set(clips), in: range, ramp: session.gainRamp)
            } catch {
                throw .session(error)
            }
            session = ridden
            return lines(changed: changed, in: ridden)
        }
        let groups: [RideGroup]
        do throws(SessionError) { groups = try session.rideGroups(Set(clips)) } catch { throw .session(error) }
        let read: RideRead
        do throws(RideReadError) {
            read = try rideLists(groups, in: session, package: package, progress: progress, isCancelled: isCancelled)
        } catch {
            throw StudioError(error)
        }
        #if DEBUG
            // The cancel test: the child says it holds, then waits for the interrupt.
            if ProcessInfo.processInfo.environment["DIRIGIBLE_RIDE_HOLD"] == "1" {
                try? FileHandle.standardError.write(contentsOf: Data("hold\n".utf8))
                while !isCancelled() { usleep(1_000) }
            }
        #endif
        guard !isCancelled() else { throw .rideCancelled }
        do throws(SessionError) { try ridden.setRides(read.rides) } catch { throw .session(error) }
        session = ridden
        return lines(changed: [], in: ridden)
    }

    /// One line for each named clip, from the session after the run. A ride: `<clip>: leveled, <lowest>
    /// to <highest> dB, <n> points` for a clip with a ride, else `<clip>: no measurement`. A remove:
    /// `<clip>: ride removed` for a clip in `changed`, else `<clip>: no ride`.
    func lines(changed: [ClipID], in session: Session) -> [String] {
        clips.map { clip in
            guard !clear else { return "\(clip): \(changed.contains(clip) ? "ride removed" : "no ride")" }
            return Self.rideLine(of: clip, in: session)
        }
    }

    private static func rideLine(of clip: ClipID, in session: Session) -> String {
        guard let summary = session.clip(clip)?.clip.rideSummary else { return "\(clip): no measurement" }
        let (low, high) = (String(format: "%.1f", summary.lowest), String(format: "%.1f", summary.highest))
        return "\(clip): leveled, \(low) to \(high) dB, \(summary.points) \(summary.points == 1 ? "point" : "points")"
    }

    /// The job of a tool call on the files, under the package lock. A ride that changes no list
    /// writes nothing.
    func run(_ package: URL, path: String, control: CallControl) throws(ToolError) -> String {
        do throws(EditFailure<StudioError>) {
            let lines = try editPackageCore(package, ripple: false, writeUnchanged: false, log: control.log) {
                session, _ throws(StudioError) in
                try run(
                    &session, package: package, progress: { control.report($0) },
                    isCancelled: { control.isCancelled() })
            }
            return lines.joined(separator: "\n")
        } catch .body(.rideCancelled) {
            // A cancelled call gets no answer, so no one reads this text.
            throw ToolError(cancelledMessage)
        } catch {
            throw ToolError(error.message(package: path))
        }
    }
}

extension EditFailure where Body == StudioError {
    package func message(package: String) -> String {
        switch self {
        case .file(let error): error.message(package: package)
        case .pendingTake: pendingTakeMessage(package)
        case .splitTake: splitTakeMessage(package)
        case .body(let error): error.message(package: package)
        }
    }
}
