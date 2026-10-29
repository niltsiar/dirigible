import DirigibleAudio
import DirigibleCore
import Foundation

/// The JSON contract for scripts and agents (decision 0011). Keys are sorted. An absent optional
/// value is left out. Tracks keep the session order and clips the lane order. Files and captures
/// sort by ID, markers by position and then ID.
package struct SessionView: Encodable {
    struct CaptureView: Encodable {
        let id: String
        let deviceUID: String
        let deviceName: String
        let hostTimeNanos: UInt64
        let sampleTime: Double
        let nominalSampleRate: Double
        let measuredSampleRate: Double
        let latency: Int
        let resampledFromRate: Double?
        let driftCorrected: Bool
    }

    struct FileView: Encodable {
        let id: String
        let path: String
        let layout: String
        let length: Int
        let capture: String?
        /// "ok", "missing", "short", or "unreadable" (decision 0016).
        let media: String
        /// The real length of a short file.
        let mediaLength: Int?
        let origin: OriginView?
    }

    /// A device route has `device` and `channels`; an app route has only `app`.
    struct RouteView: Encodable {
        let device: String?
        let channels: [Int]?
        let app: String?

        init(_ route: Route) {
            switch route {
            case .device(let uid, let channels): (device, self.channels, app) = (uid, channels.numbers, nil)
            case .app(let bundleID): (device, channels, app) = (nil, nil, bundleID)
            }
        }
    }

    struct ClipView: Encodable {
        let id: String
        let file: String
        let start: Int
        let offset: Int
        let length: Int
        let gain: Double
        /// Left out at 0, as in `session.xml` (decision 0035).
        let fadeIn: Int?
        let fadeOut: Int?
        /// Left out at 0, as in `session.xml` (decision 0036).
        let crossfadeIn: Int?
        let crossfadeOut: Int?
        /// The gain points inside the clip window as [timeline frame, dB] at full precision, the count
        /// of the points outside it, and with a point outside, the envelope gain at the first and the
        /// last frame of the window, rounded to 0.01 dB (only these two values are rounded); each left
        /// out with none (decision 0060).
        var envelope: [PointView]?
        var pointsOutside: Int?
        var windowEdges: [PointView]?
        /// Only with `compact`, in place of the three keys above: the count of all points.
        var points: Int?

        init(_ clip: Clip) {
            id = clip.id.rawValue
            file = clip.file.rawValue
            start = clip.start.count
            offset = clip.offset.count
            length = clip.length.count
            gain = clip.gain.dB
            fadeIn = clip.fades.fadeIn.nonZero
            fadeOut = clip.fades.fadeOut.nonZero
            crossfadeIn = clip.crossfades.start.nonZero
            crossfadeOut = clip.crossfades.end.nonZero
            let inside = clip.pointsInWindow
            envelope = inside.isEmpty ? nil : inside.map { PointView(frame: $0.frame.count, dB: $0.gain.dB) }
            let outside = clip.envelope.points.count - inside.count
            pointsOutside = outside == 0 ? nil : outside
            windowEdges = outside == 0 ? nil : [clip.windowEdges.first, clip.windowEdges.last]
        }

        var compacted: ClipView {
            var clip = self
            let count = (envelope?.count ?? 0) + (pointsOutside ?? 0)
            (clip.envelope, clip.pointsOutside, clip.windowEdges, clip.points) = (
                nil, nil, nil, count == 0 ? nil : count
            )
            return clip
        }
    }

    /// `[frame, dB]`, the shape of a point of the tool `clip_envelope`.
    struct PointView: Encodable {
        let frame: Int
        let dB: Double

        func encode(to encoder: any Encoder) throws {
            var container = encoder.unkeyedContainer()
            try container.encode(frame)
            try container.encode(dB)
        }
    }

    struct TrackView: Encodable {
        let id: String
        let name: String
        let gain: Double
        let layout: String
        let route: RouteView?
        var clips: [ClipView]
        /// Left out when false, as in `session.xml` (decision 0039).
        let muted: Bool?
        let soloed: Bool?
        /// Left out with no role, as in `session.xml` (decision 0060).
        let role: String?
    }

    struct MarkerView: Encodable {
        let id: String
        let name: String
        let position: Int
        let kind: String
        /// Left out when nil, as in `session.xml`. `image` is the path in the package.
        let url: String?
        let image: String?
    }

    struct RecordingView: Encodable {
        let take: Int
        let playheadFrame: Int
        let takeStartHostTimeNanos: UInt64
        let armedTracks: [String]
    }

    /// The sync state of one take with audio (decision 0061): `offset` for `inSync`, `from` and
    /// `shifts` for `broken`.
    struct TakeSyncView: Encodable {
        let take: Int
        let state: String
        let offset: Int?
        let from: Int?
        let shifts: Int?

        init(take: Int, _ sync: TakeSync) {
            self.take = take
            switch sync {
            case .inSync(let offset): (state, self.offset, from, shifts) = ("inSync", offset, nil, nil)
            case .broken(let from, let shifts):
                (state, offset, self.from, self.shifts) = ("broken", nil, from.count, shifts)
            }
        }
    }

    /// The anchor file that does not read, and its errno.
    struct FaultView: Encodable {
        let file: String
        let errno: Int32
    }

    /// The `session.xml` version that a save of this session writes (decision 0029).
    let version: Int
    let sampleRate: Int
    private(set) var captures: [CaptureView]
    private(set) var files: [FileView]
    private(set) var tracks: [TrackView]
    private(set) var markers: [MarkerView]
    let recording: RecordingView?
    /// Left out when empty (decision 0045).
    let episode: EpisodeView?
    /// One entry for each take with audio, in take order; left out with none (decision 0061).
    let takeSync: [TakeSyncView]?
    /// One entry for each anchor read fault, the fault of `Capture/` first, then in take order; left
    /// out with none.
    let takeSyncFaults: [FaultView]?

    /// `takeMap` is the take map of the session and its anchor read faults.
    package init(_ session: Session, media: [FileID: MediaFault], takeMap: TakeMapRead) {
        version = session.fileVersion
        sampleRate = session.sampleRate
        captures = session.sortedCaptures.map {
            CaptureView(
                id: $0.id.rawValue, deviceUID: $0.deviceUID, deviceName: $0.deviceName, hostTimeNanos: $0.hostTimeNanos,
                sampleTime: $0.sampleTime, nominalSampleRate: $0.nominalSampleRate,
                measuredSampleRate: $0.measuredSampleRate, latency: $0.latency, resampledFromRate: $0.resampledFromRate,
                driftCorrected: $0.driftCorrected)
        }
        files = session.sortedFiles.map {
            FileView(
                id: $0.id.rawValue, path: $0.path, layout: $0.layout.rawValue, length: $0.length.count,
                capture: $0.capture?.rawValue, media: media[$0.id].map(\.word) ?? "ok",
                mediaLength: media[$0.id].flatMap(\.length), origin: $0.origin.map(OriginView.init))
        }
        tracks = session.tracks.map { track in
            TrackView(
                id: track.id.rawValue, name: track.name, gain: track.gain.dB, layout: track.layout.rawValue,
                route: track.route.map(RouteView.init),
                clips: track.clips.map(ClipView.init), muted: track.isMuted ? true : nil,
                soloed: track.isSoloed ? true : nil, role: track.role?.rawValue)
        }
        markers = session.sortedMarkers.map {
            MarkerView(
                id: $0.id.rawValue, name: $0.name, position: $0.position.count, kind: $0.kind.rawValue,
                url: $0.url?.text, image: $0.image?.path)
        }
        episode = session.episode.isEmpty ? nil : EpisodeView(session.episode)
        let sync = takeMap.map.sync
        takeSync = sync.isEmpty ? nil : sync.sorted { $0.key < $1.key }.map { TakeSyncView(take: $0.key, $0.value) }
        let faults = takeMap.faults.map { FaultView(file: $0.error.fault.file, errno: $0.error.fault.errno) }
        takeSyncFaults = faults.isEmpty ? nil : faults
        recording = session.recording.map {
            RecordingView(
                take: $0.take, playheadFrame: $0.playheadFrame.count, takeStartHostTimeNanos: $0.takeStartHostTimeNanos,
                armedTracks: $0.armedTracks.map(\.rawValue))
        }
    }

    /// The keys of `info --json --compact` and of `session_info` with `compact`: what an agent
    /// needs to edit, with no file, capture, version, recording, or episode.
    private struct CompactView: Encodable {
        let sampleRate: Int
        let tracks: [TrackView]
        let markers: [MarkerView]
        let takeSync: [TakeSyncView]?
        let takeSyncFaults: [FaultView]?
    }

    /// Pretty JSON with a newline at the end for `info --json`, or compact JSON on one line for
    /// `session_info`. With `compact`, only `sampleRate`, `tracks`, `markers`, and the sync keys.
    package func json(pretty: Bool = true, compact: Bool = false) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if pretty { encoder.outputFormatting.insert(.prettyPrinted) }
        let data =
            compact
            ? try encoder.encode(
                CompactView(
                    sampleRate: sampleRate,
                    tracks: tracks.map { track in
                        var track = track
                        track.clips = track.clips.map(\.compacted)
                        return track
                    }, markers: markers, takeSync: takeSync, takeSyncFaults: takeSyncFaults))
            : try encoder.encode(self)
        return String(decoding: data, as: UTF8.self) + (pretty ? "\n" : "")
    }

    /// Only the `tracks`, and only the clips and markers that touch `range`: a clip touches it when
    /// `clip.start <= range.upperBound` and `range.lowerBound <= clip.end`, and a marker when its
    /// position is in `range.lowerBound...range.upperBound`. With a filter, only the files of the
    /// clips that stay and the captures of those files stay. So an agent can read a long session
    /// in parts.
    func filtered(tracks ids: Set<String>?, range: Range<Frames>?) -> SessionView {
        var view = self
        if let ids { view.tracks = tracks.filter { ids.contains($0.id) } }
        if let range {
            let (from, to) = (range.lowerBound.count, range.upperBound.count)
            for index in view.tracks.indices {
                view.tracks[index].clips = view.tracks[index].clips.filter {
                    $0.start <= to && from <= $0.start + $0.length
                }
            }
            view.markers = markers.filter { (from...to).contains($0.position) }
        }
        guard ids != nil || range != nil else { return view }
        let used = Set(view.tracks.flatMap { $0.clips.map(\.file) })
        view.files = files.filter { used.contains($0.id) }
        let captured = Set(view.files.compactMap(\.capture))
        view.captures = captures.filter { captured.contains($0.id) }
        return view
    }
}

/// The text summary of `info`: one line for the session, then one line for each object, then the
/// sync line of each take with audio, and the line of each anchor fault (decision 0061).
package func summary(
    of session: Session, name: String, media: [FileID: MediaFault], takeMap: TakeMapRead
) -> String {
    var lines = ["\(name): \(session.sampleRate) Hz"]
    for track in session.tracks {
        var line = "track \(track.id) \(quoted(track.name)) \(track.layout.rawValue) \(track.gain)"
        switch track.route {
        case nil: break
        case .device(let uid, let channels):
            line += " route \(quoted(uid)) \(channels.numbers.map(String.init).joined(separator: ","))"
        case .app(let bundleID): line += " route app \(quoted(bundleID))"
        }
        if track.isMuted { line += " muted" }
        if track.isSoloed { line += " soloed" }
        if let role = track.role { line += " role \(role.rawValue)" }
        lines.append(line)
        for clip in track.clips {
            lines.append(
                "  clip \(clip.id) file \(clip.file) start \(clip.start) offset \(clip.offset) length \(clip.length) "
                    + "\(clip.gain)"
                    + (clip.fades == .zero ? "" : " fade in \(clip.fades.fadeIn), out \(clip.fades.fadeOut)")
                    + (clip.crossfades.start == .zero ? "" : " crossfade in \(clip.crossfades.start)")
                    + (clip.crossfades.end == .zero ? "" : " crossfade out \(clip.crossfades.end)")
                    + envelopeText(of: clip))
        }
    }
    for file in session.sortedFiles {
        let capture = file.capture.map { " capture \($0)" } ?? ""
        let state = media[file.id].map { " media \($0.word)" + ($0.length.map { " \($0)" } ?? "") } ?? ""
        lines.append(
            "file \(file.id) \(quoted(file.path)) \(file.layout.rawValue) length \(file.length)\(capture)"
                + "\(originText(of: file))\(state)")
    }
    for capture in session.sortedCaptures {
        var line =
            "capture \(capture.id) \(quoted(capture.deviceName)) device \(quoted(capture.deviceUID)) "
            + "host time \(capture.hostTimeNanos) sample time \(capture.sampleTime) "
            + "rate \(capture.nominalSampleRate) measured \(capture.measuredSampleRate) latency \(capture.latency)"
        if let rate = capture.resampledFromRate { line += " resampled from \(rate)" }
        if !capture.driftCorrected { line += " drift not corrected" }
        lines.append(line)
    }
    for marker in session.sortedMarkers {
        var line = "marker \(marker.id) \(quoted(marker.name)) \(marker.kind.rawValue) at \(marker.position)"
        if let url = marker.url { line += " url \(quoted(url.text))" }
        if let image = marker.image { line += " image \(quoted(image.path))" }
        lines.append(line)
    }
    if let recording = session.recording {
        let armed = recording.armedTracks.map(\.rawValue).joined(separator: ",")
        lines.append(
            "recording take \(recording.take) at \(recording.playheadFrame) "
                + "host time \(recording.takeStartHostTimeNanos) armed \(armed)")
    }
    lines += TakeWork.syncLines(takeMap.map.sync, sampleRate: session.sampleRate)
    lines += takeMap.faults.map { TakeWork.faultLine($0.error) }
    return lines.map { $0 + "\n" }.joined()
}

/// The gain points of a clip in the `info` text: the points inside the clip window as
/// `<timeline frame>:<dB>`, as `clip envelope` takes them, the count of the points outside it, and
/// with a point outside, the gain at the first and the last frame of the window.
private func envelopeText(of clip: Clip) -> String {
    let inside = clip.pointsInWindow
    let outside = clip.envelope.points.count - inside.count
    var parts = inside.isEmpty ? [] : [" envelope " + inside.map { "\($0.frame):\($0.gain.dB)" }.joined(separator: " ")]
    if outside > 0 {
        parts.append("\(inside.isEmpty ? " " : ", ")\(outside) \(outside == 1 ? "point" : "points") outside the clip")
        let edges = clip.windowEdges
        parts.append(", window edges \(edges.first.frame):\(edges.first.dB) \(edges.last.frame):\(edges.last.dB)")
    }
    return parts.joined()
}

/// Quotes and escapes free text, so a quote or a space in a name keeps one line readable.
private func quoted(_ text: String) -> String { String(reflecting: text) }

extension MediaFault {
    fileprivate var word: String {
        switch self {
        case .missing: "missing"
        case .short: "short"
        case .unreadable: "unreadable"
        }
    }

    fileprivate var length: Int? {
        if case .short(let frames) = self { return frames.count }
        return nil
    }
}

extension Frames {
    fileprivate var nonZero: Int? { self == .zero ? nil : count }
}

extension Session {
    fileprivate var sortedCaptures: [Capture] { captures.values.sorted { $0.id < $1.id } }
    fileprivate var sortedFiles: [AudioFile] { files.values.sorted { $0.id < $1.id } }
}

extension Clip {
    /// The gain points inside the clip window, each at its timeline frame (decision 0060).
    fileprivate var pointsInWindow: [(frame: Frames, gain: Gain)] {
        let window = offset..<(offset + length)
        return envelope.points.filter { window.contains($0.frame) }.map { ($0.frame - offset + start, $0.gain) }
    }

    /// The envelope gain at the first and the last frame of the clip window, at timeline frames
    /// `start` and `start + length - 1`, rounded to 0.01 dB. The `+ 0.0` turns a negative zero into 0.
    fileprivate var windowEdges: (first: SessionView.PointView, last: SessionView.PointView) {
        func edge(_ frames: Frames) -> SessionView.PointView {
            let dB = envelope.gain(at: offset + frames)
            return SessionView.PointView(frame: (start + frames).count, dB: (dB * 100).rounded() / 100 + 0.0)
        }
        return (edge(.zero), edge(length - 1))
    }
}
