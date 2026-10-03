import AVFoundation
import Accelerate
import DirigibleCore
import Foundation

/// Plays the session mix (decision 0016): one `AVAudioEngine` with one `AVAudioPlayerNode` into
/// the main mixer, on the system default output or in offline manual rendering. An actor, so
/// the engine start and the file reads never run on the main actor.
///
/// A play schedules chunks of 0.1 s ahead of the node. A tick on the queue of the actor runs the
/// refill each half chunk, and the refill reads the node position. The next command ends the
/// tick. The tick does not wait for the `.dataConsumed` handler: AVFAudio delivers it on a queue
/// that a full cooperative pool delays (decision 0016, amended 2026-10-03).
actor Player {
    enum Output { case device, offline }
    /// Only these change the feed number. A seek or a shuttle change is a new play.
    enum Command: Sendable {
        case play(from: Frames, shuttle: Shuttle)
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
    }

    /// The chunks that one play keeps scheduled ahead of the node (a calibration knob).
    static let depth = 3

    private struct Graph {
        let engine: AVAudioEngine
        let node: AVAudioPlayerNode
        let format: AVAudioFormat
    }

    /// The running play. `scheduled` counts output frames from the play start.
    private struct Feed {
        let anchor: Frames
        let shuttle: Shuttle
        let mix: MixReader
        var scheduled = 0
    }

    /// The executor of the actor and the queue of the refill tick, with no target queue, as probe
    /// E8 measured it. On macOS 15 and later the tick is a plain dispatch block, so it needs no
    /// thread of the cooperative pool (decision 0016, amended 2026-10-03).
    private nonisolated let queue = DispatchSerialQueue(label: "Player", qos: .userInteractive)
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let package: @Sendable () throws -> URL
    private let output: Output
    /// Starts the engine. Tests give one that throws.
    private let start: @Sendable (AVAudioEngine) throws -> Void
    /// Opens a pool file. Tests give one that fails.
    private let open: MediaOpen
    /// The output frames of one chunk: 0.1 s at the session rate (a calibration knob).
    private let chunk: Int
    private var session: Session
    private var revision = 0
    private var number = 0
    private var played = 0
    /// The position while no feed runs.
    private var frame: Frames = .zero
    private var graph: Graph?
    private var feed: Feed?
    private var stop: PlaybackStop?
    /// The output presentation latency in session frames, read at each play start. The node
    /// frames run ahead of the heard frames by this much. 0 in offline rendering.
    private var latency = 0
    /// The refill tick of the running play; nil while no play runs.
    private var ticker: DispatchSourceTimer?
    /// Tests only: the ticks that ran.
    private(set) var ticks = 0
    /// The configuration-change observer of the engine, removed with the Player.
    private var observer: Observer?
    /// The mix frames under one chunk, reused.
    private var source: AVAudioPCMBuffer?

    /// Stores values only. The engine is made at the first play.
    init(
        package: @escaping @Sendable () throws -> URL, output: Output, session: Session,
        start: @escaping @Sendable (AVAudioEngine) throws -> Void = { try $0.start() },
        open: @escaping MediaOpen = openMedia
    ) {
        self.package = package
        self.output = output
        self.session = session
        self.start = start
        self.open = open
        chunk = max(1, session.sampleRate / 10)
    }

    /// Does nothing when `number` is not newer than the last feed number.
    func apply(_ command: Command, number: Int) {
        guard number > self.number else { return }
        ticker?.cancel()
        ticker = nil
        self.number = number
        frame = position()
        graph?.node.stop()
        feed = nil
        guard case .play(let start, let shuttle) = command else {
            graph?.engine.stop()
            return
        }
        frame = start
        played = number
        stop = nil
        guard let graph = makeGraph() else { return }
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
            ? Int((graph.engine.outputNode.presentationLatency * Double(session.sampleRate)).rounded()) : 0
        feed = Feed(anchor: start, shuttle: shuttle, mix: MixReader(package: url, session: session, open: open))
        refill()
        graph.node.play()
        ticker = Self.tick(self, every: .nanoseconds(chunk * 500_000_000 / session.sampleRate))
    }

    /// The session of the next chunks. The running feed goes on. Does nothing when `revision`
    /// is not newer than the last revision.
    func update(_ session: Session, revision: Int) {
        guard revision > self.revision else { return }
        self.revision = revision
        self.session = session
        feed?.mix.session = session
    }

    /// `ended`: the feed scheduled its last frame, and the output played it (the output latency
    /// after the node).
    func reading() -> Reading {
        let ended = feed.map { $0.scheduled >= length($0) && nodeFrames() - latency >= $0.scheduled } ?? false
        return Reading(
            number: number, played: played, frame: position(), ended: ended, running: graph?.engine.isRunning ?? false,
            stop: stop, faults: feed?.mix.faults ?? [:])
    }

    /// Tests only: posts the configuration change of this engine, as the system does.
    func postConfigurationChange() {
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: graph?.engine)
    }

    private func outputChanged() {
        stop = .outputChanged
    }

    /// Tests only: pulls `frames` output frames from the offline engine, as two channel arrays.
    /// Before each pull it waits until the tick has scheduled the frames, as the device clock
    /// gives it time to, so the wait ends on the frames, and one budget of 30 s for the call is
    /// only a hang guard. The budget counts only the time that the wait is awake: in a full suite
    /// the wait (`Task.sleep`) can wait more than 30 s for a pool thread. On macOS 15 the tick
    /// needs no pool thread; on macOS 14 its task hop waits too. `starve` pulls with no wait and
    /// no suspension, so the queue runs no tick and the node can run dry, as a late refill on a
    /// slow disk does.
    func renderOffline(frames: Int, starve: Bool = false) async -> [[Float]] {
        var out: [[Float]] = [[], []]
        var left = frames
        var budget = Duration.seconds(30)
        while left > 0 {
            let count = min(left, chunk)
            if !starve { await waitForFeed(count, budget: &budget) }
            let pulled = pull(count)
            for channel in 0..<2 { out[channel] += pulled?[channel] ?? [Float](repeating: 0, count: count) }
            left -= count
        }
        return out
    }

    /// Tests only: pulls `frames` output frames from the offline engine, one chunk each 0.1 s, as
    /// the device clock does, with no wait for the feed. Each pull is a `queue.asyncAfter` block
    /// with `assumeIsolated`, so no pull needs a thread of the cooperative pool; a task resume
    /// onto the queue can wait for one (probe E5). `end` is the instant of the last pull.
    @available(macOS 15, *)
    nonisolated func renderPaced(frames: Int) async -> (out: [[Float]], end: ContinuousClock.Instant) {
        await withCheckedContinuation { done in pace(frames, out: [[], []], done: done) }
    }

    @available(macOS 15, *)
    private nonisolated func pace(
        _ left: Int, out: [[Float]], done: CheckedContinuation<(out: [[Float]], end: ContinuousClock.Instant), Never>
    ) {
        queue.asyncAfter(deadline: .now() + .milliseconds(100)) {
            self.assumeIsolated { player in
                let count = min(left, player.chunk)
                let pulled = player.pull(count)
                var out = out
                for channel in 0..<2 { out[channel] += pulled?[channel] ?? [Float](repeating: 0, count: count) }
                if left > count {
                    player.pace(left - count, out: out, done: done)
                } else {
                    done.resume(returning: (out, .now))
                }
            }
        }
    }

    /// Each poll of 1 ms takes its time off `budget`, at most 10 ms. A later wake-up waited for a
    /// pool thread, not for the refill.
    private func waitForFeed(_ count: Int, budget: inout Duration) async {
        while let feed, feed.scheduled - nodeFrames() < count, feed.scheduled < length(feed), budget > .zero {
            let start = ContinuousClock.now
            try? await Task.sleep(for: .milliseconds(1))
            budget -= min(ContinuousClock.now - start, .milliseconds(10))
        }
    }

    private func pull(_ count: Int) -> [[Float]]? {
        guard let engine = graph?.engine, engine.isRunning,
            let buffer = AVAudioPCMBuffer(
                pcmFormat: engine.manualRenderingFormat, frameCapacity: AVAudioFrameCount(count)),
            (try? engine.renderOffline(AVAudioFrameCount(count), to: buffer)) == .success
        else { return nil }
        return (0..<2).map { Array(UnsafeBufferPointer(start: buffer.floatChannelData![$0], count: count)) }
    }

    /// Schedules chunks until the feed is `depth` chunks ahead of the node, or at its end. The
    /// chunks read the package that the lock holds now; a package that left its volume stops.
    private func refill() {
        guard var feed, let graph else { return }
        // An underrun (a late refill, a slow disk): the node ran dry and its time went on, so
        // the next buffer would play later than its frames say, and the playhead would run
        // ahead of the heard audio. Start the node again at the last frame that it played.
        let (scheduled, played) = (feed.scheduled, nodeFrames())
        let dry = scheduled < length(feed) && played > scheduled
        // A full or complete feed returns before the package lookup, a stat 20 times a second.
        if !dry, scheduled >= min(length(feed), played + chunk * Self.depth) { return }
        guard let url = try? package() else {
            stop = .packageUnavailable
            return
        }
        feed.mix.package = url
        if dry {
            graph.node.stop()
            feed = Feed(anchor: frame(feed, played: scheduled), shuttle: feed.shuttle, mix: feed.mix)
            self.feed = feed
        }
        defer { if dry { graph.node.play() } }
        let total = length(feed)
        let target = min(total, nodeFrames() + chunk * Self.depth)
        while feed.scheduled < target {
            let count = min(chunk, total - feed.scheduled)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: graph.format, frameCapacity: AVAudioFrameCount(count)),
                render(feed, count: count, into: buffer)
            else { return }
            // The chunk plays a file that did not open as silence: stop, as the render fails.
            if let error = feed.mix.openError {
                stop = .noFreeDescriptor(Int(error.code.rawValue))
                return
            }
            graph.node.scheduleBuffer(buffer)
            feed.scheduled += count
        }
        self.feed = feed
    }

    /// The output frames of the whole feed: to the session end (forward) or to 0 (reverse).
    private func length(_ feed: Feed) -> Int {
        let distance = feed.shuttle.direction == .forward ? feed.mix.session.end - feed.anchor : feed.anchor
        return max(0, Int((Double(distance.count) / feed.shuttle.rate.rawValue).rounded(.up)))
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
    }

    /// Made outside the actor: NotificationCenter calls it on an internal queue.
    private nonisolated static func changed(_ player: Player) -> @Sendable (Notification) -> Void {
        { [weak player] _ in
            guard let player else { return }
            Task { await player.outputChanged() }
        }
    }

    /// The frame that the user hears: the node frames less the output latency, at most the
    /// scheduled frames.
    private func position() -> Frames {
        guard let feed else { return frame }
        return frame(feed, played: min(max(0, nodeFrames() - latency), feed.scheduled))
    }

    /// The session frame after `played` output frames of the feed.
    private func frame(_ feed: Feed, played: Int) -> Frames {
        let moved = Frames(Int(Double(played) * feed.shuttle.rate.rawValue))
        return feed.shuttle.direction == .forward ? feed.anchor + moved : feed.anchor - moved
    }

    /// The output frames that the node played since its play; 0 before the first render.
    private func nodeFrames() -> Int {
        guard let node = graph?.node, let time = node.lastRenderTime, time.isSampleTimeValid || time.isHostTimeValid,
            let player = node.playerTime(forNodeTime: time)
        else { return 0 }
        return max(0, Int(player.sampleTime))
    }

    private func makeGraph() -> Graph? {
        if let graph { return graph }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(session.sampleRate), channels: 2)
        else { return nil }
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        if output == .offline {
            guard
                (try? engine.enableManualRenderingMode(
                    .offline, format: format, maximumFrameCount: AVAudioFrameCount(chunk))) != nil
            else { return nil }
        }
        observer = Observer(
            NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil, using: Self.changed(self)))
        graph = Graph(engine: engine, node: node, format: format)
        return graph
    }
}

/// A NotificationCenter observer for the life of the value.
private final class Observer: Sendable {
    /// NotificationCenter gives an opaque token that is only passed back to `removeObserver`.
    nonisolated(unsafe) private let token: any NSObjectProtocol

    init(_ token: any NSObjectProtocol) { self.token = token }

    deinit { NotificationCenter.default.removeObserver(token) }
}
