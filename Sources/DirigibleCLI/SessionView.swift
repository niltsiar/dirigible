import DirigibleAudio
import DirigibleCore
import Foundation

/// The JSON contract for scripts and agents (decision 0011). Keys are sorted. An absent optional
/// value is left out. Tracks keep the session order and clips the lane order. Files and captures
/// sort by ID, markers by position and then ID.
struct SessionView: Encodable {
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
    }

    struct MarkerView: Encodable {
        let id: String
        let name: String
        let position: Int
        let kind: String
    }

    struct RecordingView: Encodable {
        let take: Int
        let playheadFrame: Int
        let takeStartHostTimeNanos: UInt64
        let armedTracks: [String]
    }

    /// The `session.xml` version that a save of this session writes (decision 0029).
    let version: Int
    let sampleRate: Int
    private(set) var captures: [CaptureView]
    private(set) var files: [FileView]
    private(set) var tracks: [TrackView]
    private(set) var markers: [MarkerView]
    let recording: RecordingView?

    init(_ session: Session, media: [FileID: MediaFault]) {
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
                mediaLength: media[$0.id].flatMap(\.length))
        }
        tracks = session.tracks.map { track in
            TrackView(
                id: track.id.rawValue, name: track.name, gain: track.gain.dB, layout: track.layout.rawValue,
                route: track.route.map(RouteView.init),
                clips: track.clips.map {
                    ClipView(
                        id: $0.id.rawValue, file: $0.file.rawValue, start: $0.start.count, offset: $0.offset.count,
                        length: $0.length.count, gain: $0.gain.dB, fadeIn: $0.fades.fadeIn.nonZero,
                        fadeOut: $0.fades.fadeOut.nonZero, crossfadeIn: $0.crossfades.start.nonZero,
                        crossfadeOut: $0.crossfades.end.nonZero)
                }, muted: track.isMuted ? true : nil, soloed: track.isSoloed ? true : nil)
        }
        markers = session.sortedMarkers.map {
            MarkerView(id: $0.id.rawValue, name: $0.name, position: $0.position.count, kind: $0.kind.rawValue)
        }
        recording = session.recording.map {
            RecordingView(
                take: $0.take, playheadFrame: $0.playheadFrame.count, takeStartHostTimeNanos: $0.takeStartHostTimeNanos,
                armedTracks: $0.armedTracks.map(\.rawValue))
        }
    }

    /// Pretty JSON with a newline at the end for `info --json`, or compact JSON on one line for
    /// `session_info`.
    func json(pretty: Bool = true) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if pretty { encoder.outputFormatting.insert(.prettyPrinted) }
        return String(decoding: try encoder.encode(self), as: UTF8.self) + (pretty ? "\n" : "")
    }

    /// Only the `tracks`, and only the clips and markers that touch `range`: a clip touches it when
    /// `clip.start <= range.upperBound` and `range.lowerBound <= clip.end`, and a marker when its
    /// position is in `range.lowerBound...range.upperBound`. With a filter, only the files of the
    /// clips that stay and the captures of those files stay. So an agent can read a long session
    /// in parts (U9).
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

/// The text summary of `info`: one line for the session, then one line for each object.
func summary(of session: Session, name: String, media: [FileID: MediaFault]) -> String {
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
        lines.append(line)
        for clip in track.clips {
            lines.append(
                "  clip \(clip.id) file \(clip.file) start \(clip.start) offset \(clip.offset) length \(clip.length) "
                    + "\(clip.gain)"
                    + (clip.fades == .zero ? "" : " fade in \(clip.fades.fadeIn), out \(clip.fades.fadeOut)")
                    + (clip.crossfades.start == .zero ? "" : " crossfade in \(clip.crossfades.start)")
                    + (clip.crossfades.end == .zero ? "" : " crossfade out \(clip.crossfades.end)"))
        }
    }
    for file in session.sortedFiles {
        let capture = file.capture.map { " capture \($0)" } ?? ""
        let state = media[file.id].map { " media \($0.word)" + ($0.length.map { " \($0)" } ?? "") } ?? ""
        lines.append(
            "file \(file.id) \(quoted(file.path)) \(file.layout.rawValue) length \(file.length)\(capture)\(state)")
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
        lines.append("marker \(marker.id) \(quoted(marker.name)) \(marker.kind.rawValue) at \(marker.position)")
    }
    if let recording = session.recording {
        let armed = recording.armedTracks.map(\.rawValue).joined(separator: ",")
        lines.append(
            "recording take \(recording.take) at \(recording.playheadFrame) "
                + "host time \(recording.takeStartHostTimeNanos) armed \(armed)")
    }
    return lines.map { $0 + "\n" }.joined()
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
