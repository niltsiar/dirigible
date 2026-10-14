import DirigibleAudio
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
    /// The route of each grant track that the sheet showed.
    let routes: [TrackID: DeviceRoute]
    /// The end on `ContinuousClock`, which counts the sleep of the Mac.
    let end: ContinuousClock.Instant
    /// The end on the wall clock, for the reply text.
    let wallEnd: Date
    /// The take length that the grant has left, in seconds. Only a grant take uses it.
    var secondsLeft = takeSeconds

    /// Nil when a route is an app route: a grant never covers an app.
    init?(connection: AgentConnection, routes: [TrackID: Route], end: ContinuousClock.Instant, wallEnd: Date) {
        var devices: [TrackID: DeviceRoute] = [:]
        for (id, route) in routes {
            guard let device = DeviceRoute(route) else { return nil }
            devices[id] = device
        }
        (self.connection, self.routes, self.end, self.wallEnd) = (connection, devices, end, wallEnd)
    }

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
        return tracks.allSatisfy { id in session.track(id)?.route == routes[id]?.route }
    }
}

/// The device route of a grant track. The type has no app route.
struct DeviceRoute: Equatable {
    let uid: String
    let channels: Route.Channels

    /// Nil for an app route.
    init?(_ route: Route) {
        guard case .device(let uid, let channels) = route else { return nil }
        (self.uid, self.channels) = (uid, channels)
    }

    var route: Route { .device(uid: uid, channels: channels) }
}

/// A take that an agent started, while it records (decision 0050): the take row, the Dock
/// badge, and the notification read it.
struct AgentTake: Equatable {
    let take: Int
    let agent: String?
    let tracks: [String]
    let seconds: Double
    let since: ContinuousClock.Instant
    /// The ID of the notification of the take, from the start to the end.
    let noticeID = UUID().uuidString
}

/// The agent record state of a window that outlives one request (decision 0050).
struct AgentRecordState {
    /// The most requests that show a sheet or start a grant take on a window in `askWindow`.
    static let askLimit = 3
    static let askWindow = Duration.seconds(60)

    var grant: ConsentGrant?
    /// The agent take that records now, or nil (C12).
    var take: AgentTake?
    /// The times of the requests that showed a sheet or started a grant take (C11).
    var asks: [ContinuousClock.Instant] = []
    /// The clock of the grant end, the rate limit, and the key time. Tests give their own.
    var now: () -> ContinuousClock.Instant = { .now }
    /// The key time of the sheet before Record is enabled (C8). Tests of other rules give zero.
    var clickDelay = Duration.seconds(1)
    /// False in tests that give the key state of the sheet themselves: the key events of a test
    /// process are not under the control of the test.
    var followsKey = true
    /// Waits until an instant of `now`: the end of the click delay. Tests give their own.
    var delayWait: @MainActor (ContinuousClock.Instant) async -> Void = { try? await Task.sleep(until: $0) }
    /// The record time left of the request tracks (C10). Tests give their own.
    var readRecordTime: @MainActor (Studio, [TrackID]) async -> Duration? = { studio, tracks in
        await studio.remainingRecordTime(armed: tracks)
    }

    /// True when `askLimit` requests came in the last `askWindow`. It drops the older times.
    mutating func tooMany(at now: ContinuousClock.Instant) -> Bool {
        asks.removeAll { now - $0 >= Self.askWindow }
        return asks.count >= Self.askLimit
    }
}
