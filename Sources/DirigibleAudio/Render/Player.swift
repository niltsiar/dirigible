import AVFoundation
import Accelerate
import DirigibleCore
import Foundation

/// Plays the session mix (decision 0016): one `AVAudioEngine` with one `AVAudioPlayerNode` into
/// the main mixer, on the system default output, in offline manual rendering, or in paced manual
/// rendering (no device, the tick pulls at the host clock; `DIRIGIBLE_AUDIO_OUTPUT=none`). An
/// actor, so the engine start and the file reads never run on the main actor.
///
/// A play schedules chunks of 0.1 s ahead of the node. A tick on the queue of the actor runs the
/// refill each half chunk, and the refill reads the node position. The next command ends the
/// tick. The tick does not wait for the `.dataConsumed` handler: AVFAudio delivers it on a queue
/// that a full cooperative pool delays (decision 0016, amended 2026-10-03).
actor Player {
    enum Output { case device, offline, paced }
    /// Only these change the feed number. A seek or a shuttle change is a new play.
    enum Command: Sendable {
        /// `speed` applies only at the shuttle rate 1x (decision 0052). A forward play stops at
        /// `end`, else at the session end.
        case play(from: Frames, shuttle: Shuttle, speed: Speed = .one, end: Frames? = nil)
        case stop
    }

    /// `played` is the number of the last play that the Player started; `frame` is the position.
    /// `stop` is a stop that the user did not ask for; `faults` are the read faults of the feed.
    struct Reading: Sendable {
        var number: Int
        var played: Int
        var frame: Frames
        var ended: Bool
        /// The engine runs: a play started and no stop came.
        var running: Bool
        var stop: PlaybackStop?
        var faults: [FileID: MediaFault]
        /// The loudness of the heard frame (decision 0033).
        var loudness: LoudnessValues
    }

    /// The chunks that one play keeps scheduled ahead of the node (a calibration knob).
    static let depth = 3

    struct Graph {
        let engine: AVAudioEngine
        let node: AVAudioPlayerNode
        let format: AVAudioFormat
        /// The speed unit, attached but in the path only at a speed other than 1 (decision 0052).
        let unit: AVAudioUnitTimeEffect?
    }

    /// The executor of the actor and the queue of the refill tick, with no target queue, as probe
    /// E8 measured it. On macOS 15 and later the tick is a plain dispatch block, so it needs no
    /// thread of the cooperative pool (decision 0016, amended 2026-10-03).
    nonisolated let queue = DispatchSerialQueue(label: "Player", qos: .userInteractive)
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let package: @Sendable () throws -> URL
    let output: Output
    /// Starts the engine. Tests give one that throws.
    private let start: @Sendable (AVAudioEngine) throws -> Void
    /// Opens a pool file. Tests give one that fails.
    private let open: MediaOpen
    /// Finds the speed unit at the first play. Tests give one that finds nothing.
    private let speedUnit: SpeedUnitLookup
    /// The output latency of offline rendering, in session frames. Tests give one; the device
    /// output reads its own at each play.
    private let offlineLatency: Int
    /// The host clock of the paced pull. Tests give one that they move.
    let now: @Sendable () -> ContinuousClock.Instant
    /// Renders the frames of the paced pull. Tests give one that fails.
    let pacedRender:
        @Sendable (AVAudioEngine, AVAudioFrameCount, AVAudioPCMBuffer) throws -> AVAudioEngineManualRenderingStatus
    /// The parameter that sets the unit rate. Tests change it to one that the unit refuses.
    var rateParameter = kTimePitchParam_Rate
    /// The output frames of one chunk: 0.1 s at the session rate (a calibration knob).
    let chunk: Int
    private(set) var session: Session
    private var revision = 0
    private var number = 0
    private var played = 0
    /// The position while no feed runs.
    private(set) var frame: Frames = .zero
    private(set) var graph: Graph?
    private(set) var feed: Feed?
    private(set) var stop: PlaybackStop?
    /// The output presentation latency in session frames, read at each play start. The node
    /// frames run ahead of the heard frames by this much. 0 in offline rendering.
    private(set) var latency = 0
    /// The refill tick of the running play; nil while no play runs.
    private var ticker: DispatchSourceTimer?
    /// Tests only: the ticks that ran.
    private(set) var ticks = 0
    /// The configuration-change observer of the engine, removed with the Player.
    private var observer: Observer?
    /// The mix frames under one chunk, reused.
    private var source: AVAudioPCMBuffer?
    /// The old mix of a crossfade chunk, reused.
    private var fadeBuffer: AVAudioPCMBuffer?
    /// The meter of the heard mix (decision 0033).
    private(set) var loudness: PlayerLoudness
    /// The paced pull (`Player+Paced.swift`): the instant that frame 0 of the pull is owed from,
    /// the frames pulled since, and the buffer that the pull renders into.
    var pacedBase: ContinuousClock.Instant?
    var pacedPulled = 0
    var pacedBuffer: AVAudioPCMBuffer?

    /// Stores values only. The engine is made at the first play.
    init(
        package: @escaping @Sendable () throws -> URL, output: Output, session: Session,
        start: @escaping @Sendable (AVAudioEngine) throws -> Void = { try $0.start() },
        open: @escaping MediaOpen = openMedia, speedUnit: @escaping SpeedUnitLookup = findSpeedUnit,
        offlineLatency: Int = 0, now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
        pacedRender:
            @escaping @Sendable (AVAudioEngine, AVAudioFrameCount, AVAudioPCMBuffer) throws
            -> AVAudioEngineManualRenderingStatus = { try $0.renderOffline($1, to: $2) }
    ) {
        self.package = package
        self.output = output
        self.session = session
        self.start = start
        self.open = open
        self.speedUnit = speedUnit
        self.offlineLatency = offlineLatency
        self.now = now
        self.pacedRender = pacedRender
        chunk = max(1, session.sampleRate / 10)
        loudness = PlayerLoudness(sampleRate: session.sampleRate)
    }

    /// Records a change of speed of the running feed (decision 0052); `setSpeed` calls it.
    func changeFeedSpeed(to speed: Speed, step: SpeedStep) {
        feed?.step = step
        feed?.speed = speed
    }

    /// Does nothing when `number` is not newer than the last feed number.
    func apply(_ command: Command, number: Int) {
        guard number > self.number else { return }
        ticker?.cancel()
        ticker = nil
        self.number = number
        frame = position()
        loudness.stop(at: frame, played: heardFrames())
        graph?.node.stop()
        // The unit keeps the frames of the old position; a new play must not hear them.
        graph?.unit?.reset()
        feed = nil
        guard case .play(let start, let shuttle, let speed, let end) = command else {
            graph?.engine.stop()
            return
        }
        frame = start
        played = number
        stop = nil
        guard let graph = makeGraph() else { return }
        // A rewire while the engine runs costs no more than a seek during play (probe S6).
        let wanted = shuttle.rate == .one ? speed : .one
        let feedSpeed = wire(graph, speed: wanted) ? wanted : .one
        loudness.start(at: start, shuttle: shuttle, speed: feedSpeed)
        guard let url = try? package() else {
            stop = .packageUnavailable
            return
        }
        dispatchPrecondition(condition: .notOnQueue(.main))
        do {
            if !graph.engine.isRunning { try self.start(graph.engine) }
        } catch {
            stop = .outputUnavailable((error as NSError).code)
            return
        }
        latency =
            output == .device
            ? Int((graph.engine.outputNode.presentationLatency * Double(session.sampleRate)).rounded())
            : offlineLatency
        feed = Feed(
            anchor: start, shuttle: shuttle, end: end, speed: feedSpeed,
            mix: MixReader(package: url, session: session, open: open))
        refill()
        graph.node.play()
        pacedBase = now()
        pacedPulled = 0
        ticker = Self.tick(self, every: .nanoseconds(chunk * 500_000_000 / session.sampleRate))
    }

    /// The session of the next chunks. The running feed goes on. A change of the heard set or of a
    /// track gain of the tracks in both sessions crossfades the next chunk; any other change steps
    /// (decision 0039). Does nothing when `revision` is not newer than the last revision.
    func update(_ session: Session, revision: Int) {
        guard revision > self.revision else { return }
        self.revision = revision
        if let old = feed?.mix.session, feed?.fadeFrom == nil, Self.mixChanged(from: old, to: session) {
            feed?.fadeFrom = old
        }
        self.session = session
        feed?.mix.session = session
    }

    /// `ended`: the feed scheduled its last frame, and the output played it (the output latency
    /// after the node).
    func reading() -> Reading {
        loudness.heard(heardFrames())
        let ended = feed.map { $0.scheduled >= length($0) && heardFrames() >= $0.scheduled } ?? false
        return Reading(
            number: number, played: played, frame: position(), ended: ended, running: graph?.engine.isRunning ?? false,
            stop: stop, faults: feed?.mix.faults ?? [:], loudness: loudness.values)
    }

    func outputChanged() {
        stop = .outputChanged
    }

    /// Schedules chunks until the feed is `depth` chunks ahead of the node, or at its end. The
    /// chunks read the package that the lock holds now; a package that left its volume stops.
    func refill() {
        guard var feed, let graph else { return }
        // An underrun (a late refill, a slow disk): the node ran dry and its time went on, so
        // the next buffer would play later than its frames say, and the playhead would run
        // ahead of the heard audio. Start the node again at the last frame that it played.
        let (scheduled, played) = (feed.scheduled, nodeFrames())
        let dry = scheduled < length(feed) && played > scheduled
        // `depth` chunks of output time: the unit takes `speed` node frames per output frame.
        let ahead = Int((Double(chunk * Self.depth) * feed.speed.factor).rounded(.up))
        // A full or complete feed skips the package lookup (a stat), so a running play looks up
        // the package only on a tick that schedules a chunk.
        if !dry, scheduled >= min(length(feed), played + ahead) { return }
        guard let url = try? package() else {
            stop = .packageUnavailable
            return
        }
        feed.mix.package = url
        if dry {
            loudness.restart(scheduled: scheduled)
            graph.node.stop()
            feed = Feed(
                anchor: frame(feed, played: scheduled), shuttle: feed.shuttle, end: feed.end, speed: feed.speed,
                mix: feed.mix, fadeFrom: feed.fadeFrom)
            self.feed = feed
        }
        defer { if dry { graph.node.play() } }
        let total = length(feed)
        let target = min(total, nodeFrames() + ahead)
        while feed.scheduled < target {
            let count = min(chunk, total - feed.scheduled)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: graph.format, frameCapacity: AVAudioFrameCount(count)),
                render(feed, count: count, into: buffer)
            else { return }
            if let old = feed.fadeFrom {
                guard crossfade(feed, from: old, count: count, into: buffer) else { return }
                feed.fadeFrom = nil
            }
            // The chunk plays a file that did not open as silence: stop, as the render fails.
            if let error = feed.mix.openError {
                stop = .noFreeDescriptor(Int(error.code.rawValue))
                return
            }
            graph.node.scheduleBuffer(buffer)
            feed.scheduled += count
            loudness.scheduled(buffer, end: feed.scheduled)
        }
        self.feed = feed
    }

    /// Renders the next `count` output frames of the feed. Output frame k is the mix at
    /// anchor + k x rate (forward) or anchor - 1 - k x rate (reverse), by linear interpolation
    /// (tape pitch). Reverse renders its positions in forward order, then flips them.
    private func render(_ feed: Feed, count: Int, into buffer: AVAudioPCMBuffer) -> Bool {
        let rate = feed.shuttle.rate.rawValue
        let forward = feed.shuttle.direction == .forward
        let anchor = Double(feed.anchor.count)
        let first =
            forward ? anchor + Double(feed.scheduled) * rate : anchor - 1 - Double(feed.scheduled + count - 1) * rate
        let low = Int(first.rounded(.down))
        let span = Int((first + Double(count - 1) * rate).rounded(.down)) - low + 2
        if source.map({ Int($0.frameCapacity) < span }) ?? true {
            source = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(span))
        }
        guard let source else { return false }
        feed.mix.render(Frames(low)..<Frames(low + span), into: source)
        var start = Float(first - Double(low))
        var step = Float(rate)
        var positions = [Float](repeating: 0, count: count)
        vDSP_vramp(&start, &step, &positions, 1, vDSP_Length(count))
        buffer.frameLength = AVAudioFrameCount(count)
        for channel in 0..<2 {
            let out = buffer.floatChannelData![channel]
            vDSP_vlint(source.floatChannelData![channel], positions, 1, out, 1, vDSP_Length(count), vDSP_Length(span))
            if !forward { vDSP_vrvrs(out, 1, vDSP_Length(count)) }
        }
        return true
    }

    /// Renders the chunk again with the `old` session, and mixes it into `buffer` (the new mix)
    /// with a linear ramp in output order: frame k of n is old x (1 - k/n) + new x k/n.
    private func crossfade(_ feed: Feed, from old: Session, count: Int, into buffer: AVAudioPCMBuffer) -> Bool {
        if fadeBuffer.map({ Int($0.frameCapacity) < count }) ?? true {
            fadeBuffer = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(chunk))
        }
        let new = feed.mix.session
        feed.mix.session = old
        defer { feed.mix.session = new }
        guard let fadeBuffer, render(feed, count: count, into: fadeBuffer) else { return false }
        // The whole frame index, then one scale: an added step of 1/n drifts at the chunk end.
        var (zero, one, scale) = (Float(0), Float(1), 1 / Float(count))
        var ramp = [Float](repeating: 0, count: count)
        let frames = vDSP_Length(count)
        vDSP_vramp(&zero, &one, &ramp, 1, frames)
        vDSP_vsmul(ramp, 1, &scale, &ramp, 1, frames)
        for channel in 0..<2 {
            let (from, to) = (fadeBuffer.floatChannelData![channel], buffer.floatChannelData![channel])
            // to = (to - from) x ramp + from
            vDSP_vsub(from, 1, to, 1, to, 1, frames)
            vDSP_vma(to, 1, ramp, 1, from, 1, to, 1, frames)
        }
        return true
    }

    /// Starts the refill tick on `queue`. Made outside the actor: the timer calls the handler on
    /// `queue` (AGENTS.md, Audio callbacks). The leeway of 1 ms is that of probe E8.
    private nonisolated static func tick(_ player: Player, every period: DispatchTimeInterval) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: player.queue)
        timer.schedule(deadline: .now() + period, repeating: period, leeway: .milliseconds(1))
        timer.setEventHandler { [weak player, weak timer] in
            guard let player else {
                timer?.cancel()
                return
            }
            if #available(macOS 15, *) {
                player.assumeIsolated { $0.tick() }
            } else {
                // macOS 14 has no `checkIsolated` (SE-0424): `assumeIsolated` from a dispatch
                // block crashes there (probe E2). The task hop can wait for the pool.
                Task { await player.tick() }
            }
        }
        timer.activate()
        return timer
    }

    /// Returns at once after a stop: a late tick (a task hop, macOS 14) or a stop of the refill,
    /// so a failed refill does not run again each tick. After a new play, a late tick of the old
    /// play only tops up the current feed.
    private func tick() {
        guard ticker != nil, stop == nil else { return }
        ticks += 1
        refill()
        if let failure = pacedPull() { stop = failure }
        loudness.heard(heardFrames())
    }

    private func makeGraph() -> Graph? {
        if let graph { return graph }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(session.sampleRate), channels: 2)
        else { return nil }
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        let unit = speedUnit().map { AVAudioUnitTimeEffect(audioComponentDescription: $0) }
        engine.attach(node)
        if let unit { engine.attach(unit) }
        // Before the first read of `mainMixerNode`: that read binds the output node to the default
        // device, and the audio server then adds a device for the process life.
        if output != .device {
            guard
                (try? engine.enableManualRenderingMode(
                    .offline, format: format, maximumFrameCount: AVAudioFrameCount(chunk))) != nil
            else { return nil }
        }
        engine.connect(node, to: engine.mainMixerNode, format: format)
        observer = Observer(
            NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil, using: Self.changed(self)))
        graph = Graph(engine: engine, node: node, format: format, unit: unit)
        return graph
    }
}
