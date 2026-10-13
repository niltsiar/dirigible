import DirigibleCore
import Foundation

/// The one owner of each argument rule of the edit commands. The `validate()` of a command and
/// its MCP tool both call it, and each writes its own text (`--from` or `from`). Each rule gives
/// the checked value, or nil when the arguments break it.
package enum EditRules {
    /// The Host device of `track add-call`: a device with one channel, or no device.
    package enum HostDevice {
        case none
        case mono(uid: String, channel: Int)
        /// A device with no channels, or channels with no device.
        case unpaired
        /// Two channels: Host takes one.
        case stereo
    }

    /// The ranges of a ripple delete: one `from` and one `to` for each range, paired by order.
    package enum RippleRanges: Equatable {
        case ranges([Range<Frames>])
        /// No `from` and no `to`.
        case missing
        /// The counts of `from` and `to` differ.
        case unpaired
        /// The 1-based number of the first pair whose `from` is not less than its `to`: a ripple
        /// delete of nothing is refused.
        case notIncreasing(range: Int)
    }

    package static func rippleRanges(from: [Int], to: [Int]) -> RippleRanges {
        if from.isEmpty, to.isEmpty { return .missing }
        guard from.count == to.count else { return .unpaired }
        if let index = from.indices.first(where: { from[$0] >= to[$0] }) { return .notIncreasing(range: index + 1) }
        return .ranges(zip(from, to).map { Frames($0)..<Frames($1) })
    }

    package static func isPackagePath(_ url: URL) -> Bool { url.pathExtension == "dirigible" }

    /// More than 0 Hz. `Session.init` traps on a rate that is not positive.
    package static func sampleRate(_ rate: Int) -> Int? { rate > 0 ? rate : nil }

    /// `from <= to`. `Range` traps when the lower bound is above the upper bound.
    package static func frameRange(from: Int, to: Int) -> Range<Frames>? {
        from <= to ? Frames(from)..<Frames(to) : nil
    }

    /// An even number of frames, 0 or more. `Session` refuses a length over the limit.
    package static func crossfadeLength(_ count: Int) -> Frames? { count >= 0 && count % 2 == 0 ? Frames(count) : nil }

    /// One or two numbers. `Session` checks that each channel is 1 or more.
    package static func channels(_ numbers: [Int]) -> Route.Channels? {
        switch numbers.count {
        case 1: .mono(numbers[0])
        case 2: .stereo(numbers[0], numbers[1])
        default: nil
        }
    }

    package static func hostDevice(device: String?, channels: Route.Channels?) -> HostDevice {
        switch (device, channels) {
        case (nil, nil): .none
        case (let uid?, .mono(let channel)?): .mono(uid: uid, channel: channel)
        case (_?, .stereo?): .stereo
        default: .unpaired
        }
    }

    /// Exactly one route form: a device with channels, an app, or none. The outer nil is a call
    /// with no form or with two forms; the inner nil removes the route. No edit leaves the route
    /// unstated, so a layout change never removes a route by accident.
    package static func route(device: String?, channels: Route.Channels?, app: String?, none: Bool) -> Route?? {
        switch (device, channels, app, none) {
        case (let uid?, let channels?, nil, false): .some(.device(uid: uid, channels: channels))
        case (nil, nil, let app?, false): .some(.app(bundleID: app))
        case (nil, nil, nil, true): .some(nil)
        default: nil
        }
    }

    /// An app route needs process taps (macOS 14.2, A14).
    package static func appRouteAllowed(_ app: String?, tapsAvailable: Bool) -> Bool { app == nil || tapsAvailable }

    /// The first ID that is given twice. `Dictionary(uniqueKeysWithValues:)` traps on it.
    package static func firstRepeat(_ ids: [String]) -> String? {
        var seen: Set<String> = []
        return ids.first { !seen.insert($0).inserted }
    }

    package static func edge(_ word: String) -> Fades.Edge? {
        switch word {
        case "start": .start
        case "end": .end
        default: nil
        }
    }

    /// The tracks of `--track`, or all tracks when there is none (a ripple scope).
    package static func tracks(_ ids: [String], of session: Session) -> [TrackID] {
        ids.isEmpty ? session.tracks.map(\.id) : ids.map { TrackID($0) }
    }

    /// The targets of a clip set paste: `onto`, or the source tracks of the lanes.
    package static func laneTargets(of excerpt: Excerpt, onto: [String]) -> [TrackID] {
        onto.isEmpty ? excerpt.lanes.map(\.source) : onto.map { TrackID($0) }
    }

    /// True when a paste from `source` into `target` needs `--onto` and has none: the source track
    /// IDs do not name tracks of another package (decision 0042). One package (one path, or one
    /// identity) needs none.
    package static func sourceNeedsOnto(source: URL, target: URL, onto: [String]) -> Bool {
        guard onto.isEmpty else { return false }
        let same =
            source.standardizedFileURL.resolvingSymlinksInPath() == target.standardizedFileURL.resolvingSymlinksInPath()
            || PackageID.same(PackageID(lockFileOf: source), PackageID(lockFileOf: target))
        return !same
    }

    /// The paste target for each source track: `onto` in order, or the sources when `onto` is
    /// empty. Nil when there is no source or the counts differ.
    package static func pasteTargets(sources: [String], onto: [String]) -> [String]? {
        guard !sources.isEmpty else { return nil }
        if onto.isEmpty { return sources }
        return onto.count == sources.count ? onto : nil
    }

    /// A fade edit gives the fade-in, the fade-out, or both.
    package static func fadeGiven(fadeIn: Int?, fadeOut: Int?) -> Bool { fadeIn != nil || fadeOut != nil }
}
