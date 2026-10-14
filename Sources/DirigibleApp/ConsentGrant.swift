import DirigibleCore
import DirigibleMCP
import Foundation

/// A window grant (decision 0050): the user clicked Record with "Don't ask again until I close
/// this window" on. Later requests of the same connection on the same tracks with the same
/// routes start with no sheet, until the end or until the take length is used.
struct ConsentGrant {
    /// The time from the click to the end of the grant.
    static let lifetime = Duration.seconds(3600)
    /// The take length of all grant takes, and the longest request that can get a grant.
    static let takeSeconds = 7200.0

    let connection: AgentConnection
    /// The route of each grant track at the click.
    let routes: [TrackID: Route]
    /// The end on `ContinuousClock`, which counts the sleep of the Mac.
    let end: ContinuousClock.Instant
    /// The end on the wall clock, for the reply text.
    let wallEnd: Date
    /// The take length that the grant has left, in seconds. Only a grant take uses it.
    var secondsLeft = takeSeconds

    /// True when the request can get a grant (C1): it has a connection, each track has a device
    /// route, no track has a clip after the start, and the length is 2 h or less.
    static func offered(tracks: [Track], over: [String], seconds: Double, connection: AgentConnection?) -> Bool {
        guard connection != nil, over.isEmpty, seconds <= takeSeconds else { return false }
        return tracks.allSatisfy { if case .device = $0.route { true } else { false } }
    }

    /// True when the grant starts this request with no sheet (C3): the same connection, the same
    /// tracks in any order with the same routes now, no record-over, a length within the length
    /// left, and before the end.
    func covers(
        _ tracks: [TrackID], seconds: Double, connection: AgentConnection?, in session: Session, over: [String],
        now: ContinuousClock.Instant
    ) -> Bool {
        guard connection == self.connection, now < end, seconds <= secondsLeft, over.isEmpty else { return false }
        guard Set(tracks) == Set(routes.keys), tracks.count == routes.count else { return false }
        return tracks.allSatisfy { id in session.track(id)?.route == routes[id] }
    }
}

/// The agent record state of a window that outlives one request (decision 0050).
struct AgentRecordState {
    var grant: ConsentGrant?
    /// The clock of the grant end. Tests give their own.
    var now: () -> ContinuousClock.Instant = { .now }
}
