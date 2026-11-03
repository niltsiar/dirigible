import AVFoundation
import AudioToolbox
import DirigibleCore

/// Finds the speed unit, with no instance, so a check on the main actor loads no audio unit.
/// Nil when the system has no such component. Tests give one that finds nothing (decision 0052).
typealias SpeedUnitLookup = @Sendable () -> AudioComponentDescription?

/// The time-domain voice unit (`kAudioUnitSubType_AUiPodTimeOther`, rate 0.5 to 2), or nil when
/// the system has no such component (decision 0052, probe S1).
@Sendable func findSpeedUnit() -> AudioComponentDescription? {
    var description = AudioComponentDescription(
        componentType: kAudioUnitType_FormatConverter, componentSubType: kAudioUnitSubType_AUiPodTimeOther,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
    return AudioComponentFindNext(nil, &description) == nil ? nil : description
}

extension Player {
    /// A change of speed during a feed: the node frames at the change, and the node frames that
    /// the output path held then (code gate 1 item 3).
    struct SpeedStep {
        let node: Int
        let held: Double
    }

    /// The node frames in the output path, which holds `latency` output frames. A node frame is a
    /// source frame, so that is the latency x the speed (probe S3). After a `step`, the output
    /// frames from before it keep their node frames until the latency of output frames played.
    static func held(nodeFrames: Int, latency: Int, speed: Double, step: SpeedStep?) -> Double {
        let full = Double(latency) * speed
        guard let step, latency > 0 else { return full }
        let since = min(Double(latency), Double(max(0, nodeFrames - step.node)) / speed)
        return step.held * (1 - since / Double(latency)) + since * speed
    }

    /// The heard node frames: the node frames less the node frames in the output path.
    static func heard(nodeFrames: Int, latency: Int, speed: Double, step: SpeedStep? = nil) -> Int {
        max(0, nodeFrames - Int(held(nodeFrames: nodeFrames, latency: latency, speed: speed, step: step).rounded()))
    }

    /// Puts the speed unit between the node and the main mixer only at a speed other than 1, at
    /// that rate. At 1 the node feeds the main mixer, bit for bit as with no unit (decision 0052).
    /// Only `apply` calls it, after the node stops: a rewire while the node plays stops the node
    /// and drops its schedule (probe S6). False when the unit refuses the rate (0013: only `noErr` or not): then the node feeds
    /// the main mixer, and the play runs at 1x.
    func wire(_ graph: Graph, speed: Speed) -> Bool {
        guard let unit = graph.unit else { return speed == .one }
        let through = speed != .one ? setRate(unit, speed) : false
        if through != speedUnitInGraph { connect(graph, unit, through: through) }
        return through == (speed != .one)
    }

    /// Sets the rate of the unit. False when the unit refuses it (0013: only `noErr` or not).
    func setRate(_ unit: AVAudioUnitTimeEffect, _ speed: Speed) -> Bool {
        AudioUnitSetParameter(unit.audioUnit, rateParameter, kAudioUnitScope_Global, 0, Float(speed.factor), 0) == noErr
    }

    /// Connects the node to the main mixer, through the unit or not.
    private func connect(_ graph: Graph, _ unit: AVAudioUnitTimeEffect, through: Bool) {
        graph.engine.disconnectNodeOutput(graph.node)
        graph.engine.disconnectNodeOutput(unit)
        if through {
            graph.engine.connect(graph.node, to: unit, format: graph.format)
            graph.engine.connect(unit, to: graph.engine.mainMixerNode, format: graph.format)
        } else {
            graph.engine.connect(graph.node, to: graph.engine.mainMixerNode, format: graph.format)
        }
    }

    /// The node feeds the speed unit, not the main mixer.
    var speedUnitInGraph: Bool {
        guard let graph, let unit = graph.unit else { return false }
        return graph.engine.outputConnectionPoints(for: graph.node, outputBus: 0).contains { $0.node === unit }
    }

    /// Sets the rate of the unit of the running feed, with no new play: a change between two
    /// speeds other than 1 (decision 0052, S6). False when no feed plays through the unit; the
    /// caller then starts a new play.
    func setSpeed(_ speed: Speed) -> Bool {
        guard speed != .one, let graph, let current = feed?.speed, current != .one else { return false }
        // No rewire while the node plays: a rewire stops the node (probe S6).
        guard let unit = graph.unit, setRate(unit, speed) else { return false }
        let node = nodeFrames()
        let held = Self.held(nodeFrames: node, latency: latency, speed: current.factor, step: feed?.step)
        changeFeedSpeed(to: speed, step: SpeedStep(node: node, held: held))
        return true
    }

    /// The output frames that the output path holds: the term of the play start in session frames.
    var latency: Int { term.sessionFrames(sessionRate: session.sampleRate) }

    /// The term of a play whose read failed: the presentation latency of the output node.
    func presentationTerm(_ graph: Graph) -> OutputTerm {
        .manual(Int((graph.engine.outputNode.presentationLatency * Double(session.sampleRate)).rounded()))
    }

    /// The frame that the user hears: the heard node frames, at most the scheduled frames.
    func position() -> Frames {
        guard let feed else { return frame }
        return frame(feed, played: min(heardFrames(), feed.scheduled))
    }

    /// The node frames that the output played since the play.
    func heardFrames() -> Int {
        Self.heard(nodeFrames: nodeFrames(), latency: latency, speed: feed?.speed.factor ?? 1, step: feed?.step)
    }

    /// The output frames that the node played since its play; 0 before the first render.
    func nodeFrames() -> Int {
        guard let node = graph?.node, let time = node.lastRenderTime, time.isSampleTimeValid || time.isHostTimeValid,
            let player = node.playerTime(forNodeTime: time)
        else { return 0 }
        return max(0, Int(player.sampleTime))
    }

    /// Tests only: the node frames that the running feed scheduled.
    var scheduledFrames: Int { feed?.scheduled ?? 0 }
}
