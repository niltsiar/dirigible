import DirigibleCore
import Foundation

/// The result of a Level Over Time.
public struct RideReport: Hashable, Sendable {
    /// The clips that got a ride list.
    public let leveled: [ClipID]
    /// The clips of a measure group with no reference: their ride layer is empty.
    public let unmeasured: [ClipID]
    /// The ride gain of the largest size that the leveled clips play, with its sign. Nil with no list.
    public let largestGain: Gain?
}

extension Studio {
    /// Level Over Time on `clips`: the ride layer of each clip from its measure group
    /// (`Session.rideGroups`, `rideLists`), written with `Session.setRides` through `runReadJob` on
    /// the `.riding` transport. A ride that changes no list saves nothing and records no undo
    /// entry. A source fault throws `.rideFault`, no free descriptor `.rideRead`, and a cancel
    /// `.rideCancelled`; each throw changes nothing. An unknown clip throws before a read.
    public func levelOverTime(
        _ clips: Set<ClipID>, agent: AgentName?, progress: @escaping @MainActor @Sendable (Double) -> Void = { _ in }
    ) async throws(StudioError) -> RideReport {
        try checkIdle()
        let groups: [RideGroup]
        do throws(SessionError) { groups = try session.rideGroups(clips) } catch { throw .session(error) }
        return try await runReadJob(
            .riding, cancelled: .rideCancelled, agent: agent, progress: progress,
            read: { session, lock, progress, isCancelled in
                await readRides(groups, of: session, lock: lock, progress: progress, isCancelled: isCancelled)
            },
            apply: { session, read throws(StudioError) in
                var ridden = session
                do throws(SessionError) { try ridden.setRides(read.rides) } catch { throw .session(error) }
                let gains = read.leveled.lazy.compactMap { ridden.clip($0)?.clip.playedRideGains }.joined()
                let largest = gains.max { abs($0) < abs($1) }.flatMap(Gain.init(clamping:))
                return (ridden, RideReport(leveled: read.leveled, unmeasured: read.unmeasured, largestGain: largest))
            })
    }

    /// Remove Level Over Time on the clip set `clips`, as one undo entry with no audio read
    /// (`Session.removeRides` with the 500 ms range gain ramp). With `range` (timeline frames) the
    /// ride is 0 dB on it; nil empties the ride layer of each clip. It returns the clips whose ride
    /// changed. A remove that changes nothing records no entry.
    @discardableResult
    public func removeLevelOverTime(_ clips: Set<ClipID>, in range: Range<Frames>?, agent: AgentName?)
        throws(StudioError) -> [ClipID]
    {
        try edit(ripple: false, agent: agent) { session throws(SessionError) in
            try session.removeRides(clips, in: range, ramp: session.gainRamp)
        }
    }
}

/// `rideLists` off the main actor, in the package that `lock` holds now.
@concurrent nonisolated func readRides(
    _ groups: [RideGroup], of session: Session, lock: PackageLock, progress: @escaping @Sendable (Double) -> Void,
    isCancelled: @escaping @Sendable () -> Bool
) async -> Result<RideRead, StudioError> {
    dispatchPrecondition(condition: .notOnQueue(.main))
    let package: URL
    do throws(SessionFileError) { package = try lock.package() } catch { return .failure(.file(error)) }
    do throws(RideReadError) {
        return .success(
            try rideLists(groups, in: session, package: package, progress: progress, isCancelled: isCancelled))
    } catch {
        return .failure(StudioError(error))
    }
}

extension StudioError {
    /// The error of a ride read that stopped.
    package init(_ error: RideReadError) {
        switch error {
        case .cancelled: self = .rideCancelled
        case .fault(let file, let fault): self = .rideFault(file, fault)
        case .descriptor(let code): self = .rideRead(code)
        }
    }
}
