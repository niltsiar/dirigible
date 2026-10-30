import AVFoundation
import Accelerate
import DirigibleCore
import Foundation
import os

/// What the effect preview loops: the render of the window, or the sound that the render removes.
public enum Listen: Hashable, Sendable { case result, removedSound }

/// The two loops of a window, each in two channels: a mono window plays in both.
struct PreviewAudio: Sendable {
    let result: [[Float]]
    let removed: [[Float]]
    /// The measure of the de-clip that the render used, for the caller to keep.
    var measure: RepairMeasure?
}

/// Renders `window` of `session` in `package` into memory (decision 0054): a new chain for each
/// level, bottom first, the lowest on the window of the file and each other one on the output of
/// the level below. The Result drops the lead-in. The Removed Sound is the aligned input (with a
/// de-ess, its `allpassSum`) minus the Result over its scale s1: what the effects changed, at the
/// input scale. It writes no file, and it blocks: never call it on the main actor. `readFault` runs
/// at the block reads of the window file, by its stem (tests only). A window with a `measure` runs
/// step 2 of `RepairSetup` on its clip run, for the de-clip alone, unless `kept` holds the measure:
/// its s1 leaves out the overshoot of a high-pass after the de-clip (a gap of the render scale only,
/// decision 0064 D9), and a rumble step reads only the window. Every block of every level is checked
/// for a non-finite sample before the audio is given. `addedStage` runs after the post-stages of
/// the last level (tests only).
func renderPreview(
    _ window: PreviewWindow, of session: Session, in package: URL, readFault: ReadFault?,
    kept: RepairMeasure? = nil, addedStage: (any RenderStage)? = nil, isCancelled: () -> Bool
) throws(ClipRenderError) -> PreviewAudio {
    guard let file = session.files[window.file] else { throw .session(.unknownFile(window.file)) }
    let channels = file.layout.channelCount
    let rate = Double(session.sampleRate)
    let opened: (descriptor: Int32, file: AVAudioFile)
    do throws(ImportError) {
        opened = try openAudio(package.appending(path: "\(clipsFolderName)/\(file.path)"))
    } catch {
        throw ClipRenderError(error, source: file.path)
    }
    defer { close(opened.descriptor) }
    let span = AVAudioFramePosition(window.span.lowerBound.count)..<AVAudioFramePosition(window.span.upperBound.count)
    let format = opened.file.processingFormat
    let count = Int(span.upperBound - span.lowerBound)
    let read = span.lowerBound..<span.upperBound + AVAudioFramePosition(window.tail)
    let stem = URL(filePath: file.path).deletingPathExtension().lastPathComponent
    guard Int(format.channelCount) == channels, format.sampleRate == rate, opened.file.length >= read.upperBound,
        let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))
    else { throw .sourceUnreadable(file: file.path, errno: EIO) }
    var (below, measure, scale): (AVAudioPCMBuffer?, RepairMeasure?, Float) = (nil, kept, 1)
    for (index, level) in window.levels.enumerated() {
        var setup: RepairSetup
        if index == 0, let key = window.measure, let declip = level.treatment.declip {
            try RepairSetup.check(level.treatment, rate: Int(rate))
            if measure == nil {
                let run =
                    AVAudioFramePosition(key.run.lowerBound.count)..<AVAudioFramePosition(key.run.upperBound.count)
                measure = try repairSetup(
                    span: run, of: opened.file, descriptor: opened.descriptor, treatment: Treatment(.declip(declip)),
                    file: file.path, stem: stem, readFault: readFault, isCancelled: isCancelled
                ).measure
            }
            setup = try .measured(measure!, level.treatment, rate: rate, channels: channels)
        } else {
            setup = try .unmeasured(level.treatment, rate: rate, channels: channels)
        }
        if index == window.levels.count - 1, let addedStage { setup.post.append(addedStage) }
        scale *= setup.scale
        let chain = try EffectChain(
            level.treatment, scale: setup.scale, rate: rate, channels: channels, component: .soundIsolation,
            repair: setup)
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count + window.tail))
        else { throw .engine(status: kAudio_MemFullError) }
        let sink = { (buffer: AVAudioPCMBuffer) throws(ClipRenderError) in
            try RepairSetup.checkFinite(buffer, file: file.path)
            append(buffer, to: output)
        }
        if let below {
            _ = try chain.render(below, into: sink, isCancelled: isCancelled)
        } else {
            _ = try chain.render(
                opened.file, descriptor: opened.descriptor, span: read, into: sink, file: file.path, stem: stem,
                readFault: readFault, isCancelled: isCancelled, rendered: { _ in })
        }
        below = output
    }
    opened.file.framePosition = span.lowerBound
    do { try opened.file.read(into: input, frameCount: AVAudioFrameCount(count)) } catch {
        throw .sourceUnreadable(file: file.path, errno: ioErrno(of: error, file: opened.descriptor) ?? EIO)
    }
    guard let below, Int(below.frameLength) == count + window.tail, Int(input.frameLength) == count else {
        throw .sourceUnreadable(file: file.path, errno: EIO)
    }
    let frames = count - window.leadIn
    let deess = window.levels.lazy.compactMap(\.treatment.deess).first
    let reference = deess.map { allpassSum(input.samples(), hertz: $0.hertz, rate: rate) } ?? input.samples()
    var (result, removed): ([[Float]], [[Float]]) = ([], [])
    for channel in 0..<2 {
        let from = min(channel, channels - 1)
        let rendered = UnsafeBufferPointer(start: below.floatChannelData![from] + window.leadIn, count: frames)
        result.append(Array(rendered))
        removed.append(vDSP.subtract(reference[from][window.leadIn...], vDSP.divide(rendered, scale)))
    }
    return PreviewAudio(result: result, removed: removed, measure: window.measure == nil ? nil : measure)
}

/// Appends the frames of `buffer` to `output`. The render gives at most the frames of its span.
private func append(_ buffer: AVAudioPCMBuffer, to output: AVAudioPCMBuffer) {
    let (at, frames) = (Int(output.frameLength), Int(buffer.frameLength))
    for channel in 0..<Int(output.format.channelCount) {
        (output.floatChannelData![channel] + at).update(from: buffer.floatChannelData![channel], count: frames)
    }
    output.frameLength += AVAudioFrameCount(frames)
}

/// Loops the preview of a clip render (decision 0054): one `AVAudioEngine` with one
/// `AVAudioPlayerNode`, on the system default output or in offline manual rendering. Only a test
/// pulls the offline engine: with the paced output, the loop plays no frame and opens no device.
/// An actor, so the engine work never runs on the main actor. The node plays the window
/// with `.loops`. When a new window is ready, the node stops and plays it from its first frame in
/// one turn of the actor, so the old loop plays until then and the new loop starts aligned with
/// the window. No completion handler and no render block of this type runs on the audio
/// thread (decision 0013, **Callbacks**).
///
/// Each call has a number from `Studio`; `supersede` sets the newest one with no wait, so a render
/// of an older call ends at its next block, and an older call changes nothing.
actor EffectPreview {
    struct Graph {
        let engine: AVAudioEngine
        let node: AVAudioPlayerNode
        let format: AVAudioFormat
    }

    /// The number of the newest call. Each block of a render reads it.
    nonisolated let latest = OSAllocatedUnfairLock(initialState: 0)
    private let package: @Sendable () throws(SessionFileError) -> URL
    private let output: Player.Output
    private let rate: Int
    private let start: @Sendable (AVAudioEngine) throws -> Void
    private let readFault: ReadFault?
    /// Makes the stage that runs after the last level (tests only).
    private let addedStage: (@Sendable () -> any RenderStage)?
    /// Gets the number of the newest call when a configuration change of the engine stops the loop.
    private let ended: @Sendable (Int) -> Void
    private(set) var graph: Graph?
    private var observer: Player.Observer?
    /// The window that the node loops, and its audio.
    private var shown: (window: PreviewWindow, audio: PreviewAudio)?
    /// The last measure of a de-clip with its key. A file never changes under its ID, so the key
    /// holds the values that the measure depends on.
    private var kept: (key: PreviewMeasure, measure: RepairMeasure)?
    /// Tests only: the windows that a render made, and the measures that a render ran.
    private(set) var windows = 0
    private(set) var measures = 0

    /// Stores values only. The engine is made at the first play.
    init(
        package: @escaping @Sendable () throws(SessionFileError) -> URL, output: Player.Output, rate: Int,
        start: @escaping @Sendable (AVAudioEngine) throws -> Void = { try $0.start() }, readFault: ReadFault? = nil,
        addedStage: (@Sendable () -> any RenderStage)? = nil, ended: @escaping @Sendable (Int) -> Void
    ) {
        self.addedStage = addedStage
        self.package = package
        self.output = output
        self.rate = rate
        self.start = start
        self.readFault = readFault
        self.ended = ended
    }

    /// Makes `number` the newest call, so each older call ends with no change.
    nonisolated func supersede(_ number: Int) { latest.withLock { $0 = max($0, number) } }

    private func isNewest(_ number: Int) -> Bool { latest.withLock { $0 } == number }

    /// Loops `window` of `session` as `listen` for the call `number`. The window that loops now
    /// only changes what loops; another window renders off the actor first. False when a newer
    /// call came first: then nothing changed. A package that left its volume throws `.file`, and a
    /// render or engine fault `.clipRender`; a fault stops the loop first. A fault of a call that a
    /// newer call superseded gives false, so it never stops the loop of the newer call.
    func play(_ window: PreviewWindow, of session: Session, listen: Listen, number: Int) async throws(StudioError)
        -> Bool
    {
        guard isNewest(number) else { return false }
        do throws(StudioError) {
            return try await loop(window, of: session, listen: listen, number: number)
        } catch {
            guard isNewest(number) else { return false }
            halt()
            throw error
        }
    }

    private func loop(_ window: PreviewWindow, of session: Session, listen: Listen, number: Int)
        async throws(StudioError) -> Bool
    {
        var audio = shown.flatMap { $0.window == window ? $0.audio : nil }
        if audio == nil {
            let url: URL
            do throws(SessionFileError) { url = try package() } catch { throw .file(error) }
            let known = kept.flatMap { $0.key == window.measure ? $0.measure : nil }
            let made = await renderOffActor(
                window, of: session, in: url, readFault: readFault, kept: known, addedStage: addedStage,
                latest: latest, number: number)
            switch made {
            case .success(let made): audio = made
            case .failure(.cancelled): return false
            case .failure(let error): throw .clipRender(error)
            }
            windows += 1
            if known == nil, let key = window.measure, let measure = audio?.measure {
                kept = (key, measure)
                measures += 1
            }
        }
        guard isNewest(number), let audio else { return false }
        shown = (window, audio)
        do throws(ClipRenderError) { try schedule(listen == .result ? audio.result : audio.removed) } catch {
            throw .clipRender(error)
        }
        return true
    }

    /// Stops the loop for the call `number`, unless a newer call came first.
    func stop(_ number: Int) {
        guard isNewest(number) else { return }
        halt()
    }

    /// A configuration change of the engine: the loop stops, and `ended` gets the newest number.
    /// The newest number goes up by one at once, so a window render in flight ends at its next
    /// block before `ended` reaches the main actor. The stop number that `Studio` then takes is
    /// that same number.
    func outputChanged() {
        halt()
        ended(
            latest.withLock { number in
                defer { number += 1 }
                return number
            })
    }

    private func halt() {
        graph?.node.stop()
        graph?.engine.stop()
        shown = nil
    }

    private func schedule(_ channels: [[Float]]) throws(ClipRenderError) {
        guard let graph = makeGraph(),
            let buffer = AVAudioPCMBuffer(pcmFormat: graph.format, frameCapacity: AVAudioFrameCount(channels[0].count))
        else { throw .engine(status: kAudio_MemFullError) }
        buffer.frameLength = buffer.frameCapacity
        for (index, channel) in channels.enumerated() {
            channel.withUnsafeBufferPointer {
                buffer.floatChannelData![index].update(from: $0.baseAddress!, count: $0.count)
            }
        }
        dispatchPrecondition(condition: .notOnQueue(.main))
        do {
            if !graph.engine.isRunning { try start(graph.engine) }
        } catch {
            throw .engine(status: Int32((error as NSError).code))
        }
        graph.node.stop()
        graph.node.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
        graph.node.play()
    }

    private func makeGraph() -> Graph? {
        if let graph { return graph }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 2) else { return nil }
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        engine.attach(node)
        // Before the first read of `mainMixerNode`, as the Player.
        if output != .device {
            guard (try? engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)) != nil
            else { return nil }
        }
        engine.connect(node, to: engine.mainMixerNode, format: format)
        observer = Player.Observer(
            NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil, using: Self.changed(self)))
        graph = Graph(engine: engine, node: node, format: format)
        return graph
    }

    /// Made outside the actor: NotificationCenter calls it on an internal queue.
    private nonisolated static func changed(_ preview: EffectPreview) -> @Sendable (Notification) -> Void {
        { [weak preview] _ in
            guard let preview else { return }
            Task { await preview.outputChanged() }
        }
    }

    /// Tests only: pulls `frames` output frames from the offline engine, as two channel arrays.
    func renderOffline(frames: Int) -> [[Float]] {
        var out: [[Float]] = [[], []]
        guard let engine = graph?.engine,
            let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096)
        else { return out }
        var left = frames
        while left > 0 {
            let count = min(left, 4096)
            guard (try? engine.renderOffline(AVAudioFrameCount(count), to: buffer)) == .success else { return out }
            for channel in 0..<2 {
                out[channel] += UnsafeBufferPointer(start: buffer.floatChannelData![channel], count: count)
            }
            left -= count
        }
        return out
    }

    /// Tests only: posts the configuration change of this engine, as the system does.
    func postConfigurationChange() {
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: graph?.engine)
    }
}

/// `renderPreview` on a user-initiated GCD thread, off the actor, as `renderOffMain` runs a clip
/// render on a utility thread. It ends at the next block when `latest` is no longer `number`.
@concurrent nonisolated private func renderOffActor(
    _ window: PreviewWindow, of session: Session, in package: URL, readFault: ReadFault?, kept: RepairMeasure?,
    addedStage: (@Sendable () -> any RenderStage)?, latest: OSAllocatedUnfairLock<Int>, number: Int
) async -> Result<PreviewAudio, ClipRenderError> {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            dispatchPrecondition(condition: .notOnQueue(.main))
            do throws(ClipRenderError) {
                let audio = try renderPreview(
                    window, of: session, in: package, readFault: readFault, kept: kept, addedStage: addedStage?(),
                    isCancelled: { latest.withLock { $0 } != number })
                continuation.resume(returning: .success(audio))
            } catch {
                continuation.resume(returning: .failure(error))
            }
        }
    }
}
