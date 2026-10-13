import AVFoundation
import AudioToolbox

/// Makes the speed unit of a Player, or nil when the unit does not load. Tests give one that
/// gives nil (decision 0048).
typealias SpeedUnitFactory = @Sendable () -> AVAudioUnitTimeEffect?

/// The time-domain voice unit (`kAudioUnitSubType_AUiPodTimeOther`, rate 0.5 to 2), or nil when
/// the system has no such component (decision 0048, probe S1).
@Sendable func makeSpeedUnit() -> AVAudioUnitTimeEffect? {
    var description = AudioComponentDescription(
        componentType: kAudioUnitType_FormatConverter, componentSubType: kAudioUnitSubType_AUiPodTimeOther,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
    guard AudioComponentFindNext(nil, &description) != nil else { return nil }
    return AVAudioUnitTimeEffect(audioComponentDescription: description)
}

extension Player {
    /// The heard node frames: the node frames less the output latency (output frames). A node
    /// frame is a source frame, so the latency in node frames is the latency x the speed (probe S3).
    static func heard(nodeFrames: Int, latency: Int, speed: Double) -> Int {
        max(0, nodeFrames - Int((Double(latency) * speed).rounded()))
    }

    /// Puts the speed unit between the node and the main mixer only at a speed other than 1, at
    /// that rate. At 1 the node feeds the main mixer, bit for bit as with no unit (decision 0048).
    /// The caller stopped the node: a rewire while the node plays drops its schedule (probe S6).
    func wire(_ graph: Graph, speed: Double) {
        guard let unit = graph.unit else { return }
        if speed != 1 {
            AudioUnitSetParameter(unit.audioUnit, kTimePitchParam_Rate, kAudioUnitScope_Global, 0, Float(speed), 0)
        }
        guard (speed != 1) != speedUnitInGraph else { return }
        graph.engine.disconnectNodeOutput(graph.node)
        graph.engine.disconnectNodeOutput(unit)
        if speed != 1 {
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

    /// Tests only: the node frames that the running feed scheduled.
    var scheduledFrames: Int { feed?.scheduled ?? 0 }
}
