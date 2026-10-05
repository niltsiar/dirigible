import AppKit
import DirigibleAudio
import DirigibleCore
import DirigibleTimeline

/// The live take that the lanes draw (live take view): a drawn input outside `LaneInputs`. The
/// document view makes it at each draw from the studio, so it holds the bins only for the draw. A
/// copy that the view kept would make the next add of the studio copy all the bins.
struct LiveLanes {
    /// A take that records or finalizes.
    struct Take {
        var number: Int
        var finalizing: Bool
        /// The record head of the last live tick, not the clock: so a full draw and the partial
        /// draws of the ticks agree.
        var head: Frames
        /// The bins and the state of each armed track. The state is nil after the stop.
        var tracks: [TrackID: (peaks: LivePeaks, state: LiveTrack.State?)]

        /// The frames of the live region of `peaks`: from the take start to the head or to the
        /// last covered frame, the later.
        func span(_ peaks: LivePeaks) -> Range<Frames> {
            let covered = peaks.covered.last.map { peaks.origin + $0.upperBound } ?? peaks.origin
            return peaks.origin..<max(head, covered)
        }

        /// The box of the live region of each armed lane in document points, on the pixel
        /// columns that the live draw fills.
        func boxes(_ inputs: LaneInputs, scale: Double) -> [Int: NSRect] {
            guard let geometry = inputs.geometry else { return [:] }
            var boxes: [Int: NSRect] = [:]
            for (lane, track) in inputs.session.tracks.enumerated() {
                guard let peaks = tracks[track.id]?.peaks else { continue }
                let span = span(peaks)
                let x0 = (geometry.x(of: span.lowerBound) * scale).rounded(.down) / scale
                let x1 = (geometry.x(of: span.upperBound) * scale).rounded(.up) / scale
                boxes[lane] = NSRect(
                    x: x0, y: Double(lane) * inputs.laneHeight, width: max(0, x1 - x0), height: inputs.laneHeight)
            }
            return boxes
        }

        /// The text of the take label: `take.recording`, or `take.finishing` during the finalize.
        var label: String { (finalizing ? L10n.takeFinishing : .takeRecording).format(number) }
    }

    var take: Take?
    /// The live peaks of each take file until its peaks are ready, and the timeline frame of its
    /// file frame 0.
    var files: [FileID: (peaks: LivePeaks, anchor: Frames)] = [:]
}

extension LiveLanes {
    /// The live take of `studio`, with `head`, the record head of the last live tick. No take
    /// when `head` is nil.
    @MainActor init(_ studio: Studio, head: Frames?) {
        files = studio.liveFiles
        guard let head, let recording = studio.session.recording else { return }
        let finalizing: Bool
        switch studio.transport {
        case .recording: finalizing = false
        case .finalizing: finalizing = true
        case .idle, .placing, .leveling, .importing: return
        }
        var tracks: [TrackID: (peaks: LivePeaks, state: LiveTrack.State?)] = [:]
        for id in recording.armedTracks {
            if let peaks = studio.livePeaks(of: id) { tracks[id] = (peaks, studio.liveTracks[id]?.state) }
        }
        take = Take(number: recording.take, finalizing: finalizing, head: head, tracks: tracks)
    }
}

extension LaneRenderer {
    /// The live region of each armed lane in the rect, over the clips (record over): the lane
    /// color over the region, the clip color over the covered frames and, while the track
    /// records, to the head, then the waveform of the bins. The waveform takes the columns whose
    /// first frame is covered, as a clip does, so the hand-off keeps the pixels.
    func drawLive(
        _ take: LiveLanes.Take, _ inputs: LaneInputs, _ palette: LanePalette, into region: borrowing PixelRegion
    ) {
        let window = region.window
        guard !region.rect.isEmpty, let geometry = inputs.geometry else { return }
        let scale = window.scale
        let pixelFrames = inputs.scale.framesPerPoint / scale
        let tracks = inputs.session.tracks
        /// The pixel columns of `frames`: the first column rounds by `start`, the end rounds up.
        func columns(_ frames: Range<Frames>, _ start: FloatingPointRoundingRule) -> Range<Int> {
            let first = Int((geometry.x(of: frames.lowerBound) * scale).rounded(start))
            return first..<max(first, Int((geometry.x(of: frames.upperBound) * scale).rounded(.up)))
        }
        for lane in window.lanes(of: region.rect.rows).clamped(to: tracks.indices) {
            let track = tracks[lane]
            guard let (peaks, state) = take.tracks[track.id] else { continue }
            let rows = window.rows(of: lane..<lane + 1)
            let origin = peaks.origin
            let covered = peaks.covered.map { origin + $0.lowerBound..<origin + $0.upperBound }
            region.fill(palette.lane, columns: columns(take.span(peaks), .down), rows: rows)
            var boxes = covered
            let end = covered.last?.upperBound ?? origin
            // A lost device or a failed write leaves a gap: the box goes on with the next span.
            if !take.finalizing, state == .recording, end < take.head { boxes.append(end..<take.head) }
            for box in boxes { region.fill(palette.clip, columns: columns(box, .down), rows: rows) }
            for frames in covered {
                let range = columns(frames, .up).clamped(to: region.rect.columns)
                guard !range.isEmpty else { continue }
                resize(range.count)
                peaks.fill(
                    &values, from: Double(range.lowerBound) * pixelFrames - Double(origin.count), step: pixelFrames)
                drawColumns(range, gain: track.gain.dB, bottom: rows.upperBound - 1, palette, into: region)
            }
        }
    }
}
