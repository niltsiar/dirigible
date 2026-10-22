import DirigibleAudio
import DirigibleCore
import Foundation

/// The arguments of `take map` and `take_map` (decision 0061). The command and the tool share
/// the argument rules and the text.
package struct TakeMapQuery: Sendable {
    /// Take frames of `take`, or timeline frames with `timeline`.
    let frames: [Int]
    let take: Int?
    let timeline: Bool
    /// Empty: every track.
    let tracks: [TrackID]

    /// Refuses a timeline frame outside 0...`Frames.limit`, a take frame outside
    /// `TakeMap.takeFrames`, and a take under 1.
    package init(frames: [Int], take: Int?, timeline: Bool, tracks: [TrackID]) throws(ToolError) {
        let bound = timeline ? 0...Frames.limit.count : TakeMap.takeFrames
        guard frames.allSatisfy(bound.contains) else {
            throw ToolError("Each frame must be \(bound.lowerBound) to \(bound.upperBound).")
        }
        if let take, take < 1 { throw ToolError("The take must be 1 or more.") }
        (self.frames, self.take, self.timeline, self.tracks) = (frames, take, timeline, tracks)
    }
}

/// Why `take map` gives no map.
package enum TakeMapError: Error {
    /// A take anchor does not read: the CLI exits 2, as for a package that does not read.
    case anchor(FinalizeError)
    /// The session has two takes with audio or more, and the query names none: exit 64.
    case takeNeeded([Int])
    /// No take audio, a take with no audio, or an unknown track: exit 1.
    case noTakeAudio
    case noSuchTake(Int, takes: [Int])
    case unknownTrack(TrackID)

    package var message: String {
        switch self {
        case .anchor(let error):
            "cannot read the take anchor \(error.fault.file) (errno \(error.fault.errno)), so the take time is not known."
        case .takeNeeded(let takes): "Give --take: the session has takes \(list(takes))."
        case .noTakeAudio: "The session has no take audio with a take time."
        case .noSuchTake(let take, let takes):
            "Take \(take) has no audio with a take time. The session has takes \(list(takes))."
        case .unknownTrack(let id): SessionError.unknownTrack(id).message
        }
    }
}

private func list(_ takes: [Int]) -> String { takes.map(String.init).joined(separator: ", ") }

/// The text of the take map and of the sync state (decision 0061).
package enum TakeWork {
    /// A place of a frame: a timeline frame, or a take frame with `timeline`.
    struct Place: Encodable {
        let track: String
        let frame: Int
    }

    struct Row: Encodable {
        let frame: Int
        let places: [Place]
    }

    /// The JSON of `take map --json`.
    struct Answer: Encodable {
        let take: Int
        let frames: [Row]
    }

    /// One line for each frame of `query`: `<frame> <track>:<frame> ...`, or `<frame> cut` for a
    /// take frame that no clip plays, or `<frame> none` for a timeline frame with no audio of the take.
    /// With `json`, one JSON object: the take and each frame with its places.
    package static func text(
        _ result: Result<TakeMap, FinalizeError>, session: Session, query: TakeMapQuery, json: Bool = false
    ) throws(TakeMapError) -> String {
        let map: TakeMap
        switch result {
        case .success(let found): map = found
        case .failure(let error): throw .anchor(error)
        }
        let takes = map.sync.keys.sorted()
        if let unknown = query.tracks.first(where: { session.track($0) == nil }) { throw .unknownTrack(unknown) }
        guard let first = takes.first else { throw .noTakeAudio }
        let take: Int
        switch query.take {
        case nil:
            guard takes.count == 1 else { throw .takeNeeded(takes) }
            take = first
        case let given?:
            guard takes.contains(given) else { throw .noSuchTake(given, takes: takes) }
            take = given
        }
        let tracks = session.tracks.map(\.id).filter { query.tracks.isEmpty || query.tracks.contains($0) }
        let rows = query.frames.map { frame in
            let places =
                query.timeline
                ? tracks.compactMap { track in
                    map.take(atTimeline: Frames(frame), on: track).flatMap {
                        $0.take == take ? Place(track: track.rawValue, frame: $0.frame) : nil
                    }
                }
                : map.timeline(atTake: frame, take: take).filter { tracks.contains($0.track) }.map {
                    Place(track: $0.track.rawValue, frame: $0.frame.count)
                }
            return Row(frame: frame, places: places)
        }
        guard json else {
            let empty = query.timeline ? "none" : "cut"
            return rows.map { row in
                "\(row.frame) "
                    + (row.places.isEmpty ? empty : row.places.map { "\($0.track):\($0.frame)" }.joined(separator: " "))
                    + "\n"
            }.joined()
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // `Answer` holds only strings and integers, so the encode does not fail.
        let data = (try? encoder.encode(Answer(take: take, frames: rows))) ?? Data()
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    /// The `info` lines of the sync state, one for each take in take order.
    package static func syncLines(_ sync: [Int: TakeSync], sampleRate: Int) -> [String] {
        sync.sorted { $0.key < $1.key }.map { take, state in
            switch state {
            case .inSync(let offset):
                "sync take \(take) in sync, offset \(seconds(offset, sampleRate)) s (\(offset) frames)"
            case .broken(let from, let shifts):
                "sync take \(take) broken from \(clock(from.count, sampleRate)) (\(from.count)), \(shifts) shifts"
            }
        }
    }

    /// Runs `edit` on `session` and gives its result with the note of the take sync change. An MCP
    /// edit tool calls it inside the body that it gives `editPackageCore`, so the anchors read under
    /// the package lock. An anchor fault gives no note: `session_info` shows the fault.
    static func noted<Result, Failure: Error>(
        _ session: inout Session, package: URL, _ edit: (inout Session) throws(Failure) -> Result
    ) throws(Failure) -> (result: Result, note: [String]) {
        let before = session
        let result = try edit(&session)
        let anchors = TakeAnchors.result(package)
        guard case .success(let old) = TakeMap.of(before, anchors: anchors),
            case .success(let new) = TakeMap.of(session, anchors: anchors)
        else { return (result, []) }
        return (result, note(TakeSync.change(from: old.sync, to: new.sync), sampleRate: session.sampleRate))
    }

    /// The note of a live call of `agent` that started at `revision`: the change of the studio when
    /// a newer revision of that agent made it, so a no-op edit and a user edit give no line.
    @MainActor static func note(_ studio: Studio, after revision: Int, agent: AgentName) -> [String] {
        let change = studio.takeSyncChange
        guard change.revision > revision, change.agent == agent else { return [] }
        return note(change.changes, sampleRate: studio.session.sampleRate)
    }

    /// One line for each change, for example `Take sync: take 4 in sync, offset -29.496 s -> broken
    /// from 0:21:07.000 (2 shifts)`, or `Take sync: take 4 offset -29.496 s -> -24.496 s (+5.000 s)`.
    static func note(_ changes: [TakeSync.Change], sampleRate: Int) -> [String] {
        func state(_ sync: TakeSync) -> String {
            switch sync {
            case .inSync(let offset): "in sync, offset \(seconds(offset, sampleRate)) s"
            case .broken(let from, let shifts): "broken from \(clock(from.count, sampleRate)) (\(shifts) shifts)"
            }
        }
        return changes.map { change in
            if case .inSync(let old) = change.old, case .inSync(let new) = change.new {
                let moved = seconds(new - old, sampleRate)
                return "Take sync: take \(change.take) offset \(seconds(old, sampleRate)) s -> "
                    + "\(seconds(new, sampleRate)) s (\(new > old ? "+" : "")\(moved) s)"
            }
            return "Take sync: take \(change.take) \(state(change.old)) -> \(state(change.new))"
        }
    }

    /// `frames` in whole milliseconds, half away from zero.
    static func milliseconds(_ frames: Int, _ sampleRate: Int) -> Int {
        Int((Double(frames) * 1000 / Double(sampleRate)).rounded())
    }

    /// Seconds with three decimals, for example -29.496.
    static func seconds(_ frames: Int, _ sampleRate: Int) -> String {
        let ms = milliseconds(frames, sampleRate)
        return "\(ms < 0 ? "-" : "")\(abs(ms) / 1000).\(digits(abs(ms) % 1000, 3))"
    }

    /// H:MM:SS.mmm, for example 0:21:07.000.
    static func clock(_ frames: Int, _ sampleRate: Int) -> String {
        let ms = milliseconds(frames, sampleRate)
        let (hours, minutes, rest) = (ms / 3_600_000, ms / 60_000 % 60, ms % 60_000)
        return
            "\(ms < 0 ? "-" : "")\(abs(hours)):\(digits(abs(minutes), 2)):\(digits(abs(rest) / 1000, 2)).\(digits(abs(rest) % 1000, 3))"
    }

    private static func digits(_ value: Int, _ count: Int) -> String {
        String(repeating: "0", count: max(0, count - String(value).count)) + String(value)
    }

    /// The `info` line of an anchor read fault.
    package static func faultLine(_ error: FinalizeError) -> String {
        "sync anchor unreadable: \(error.fault.file) (errno \(error.fault.errno))"
    }
}
