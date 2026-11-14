import AppKit
import DirigibleTimeline

/// The wheel steps of the scale strip: one step for a notch of a mouse wheel, one for each 40 pt of
/// a trackpad (the 40 of the horizontal zoom), at most one in 100 ms of event time, none from
/// momentum. A burst inside the gap is dropped, not kept for later.
struct WaveformWheel {
    /// The trackpad delta of one step, in points.
    static let pointsPerStep = 40.0
    /// The least time between two steps, in seconds.
    static let gap = 0.1

    private var lastStep: TimeInterval?
    private var pending = 0.0

    /// The step that one event gives: 1 zooms in, -1 zooms out, 0 is none.
    mutating func step(
        deltaY: Double, precise: Bool, phase: NSEvent.Phase, momentum: NSEvent.Phase, time: TimeInterval
    ) -> Int {
        guard momentum.isEmpty, deltaY != 0 else { return 0 }
        let direction = deltaY > 0 ? 1 : -1
        if precise {
            if phase.contains(.began) || (pending > 0) != (deltaY > 0) { pending = 0 }
            pending += deltaY
            guard abs(pending) >= Self.pointsPerStep else { return 0 }
            pending = 0
        }
        if let lastStep, time - lastStep < Self.gap { return 0 }
        lastStep = time
        return direction
    }
}

extension WaveformScaleStrip {
    /// Command-wheel steps the range of the window, up is Zoom In. A wheel with no Command goes up
    /// the responder chain to the lanes, as over the header rows.
    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else { return super.scrollWheel(with: event) }
        let step = wheel.step(
            deltaY: Double(event.scrollingDeltaY), precise: event.hasPreciseScrollingDeltas, phase: event.phase,
            momentum: event.momentumPhase, time: event.timestamp)
        if step != 0 { model?.zoomWaveform(step > 0 ? .waveformZoomIn : .waveformZoomOut) }
    }
}
