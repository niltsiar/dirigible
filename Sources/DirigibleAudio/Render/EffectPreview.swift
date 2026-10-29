import AVFoundation
import Accelerate
import DirigibleCore
import Foundation
import os

/// What the effect preview loops: the render of the window, or the sound that the render removes.
public enum Listen: Hashable, Sendable { case result, removedSound }

/// The audio that a preview renders: frames `span` of `file`, the first `leadIn` of which the
/// preview drops, through one chain for each request of `levels`, bottom first.
struct PreviewWindow: Hashable, Sendable {
    let file: FileID
    let span: Range<Frames>
    let leadIn: Int
    let levels: [ClipRenderRequest]
}

/// The window of a preview of `request` on `clip` (decision 0054). The levels are those of
/// `levelRequests`, as the clip render builds them, at any setting: a preview has no unchanged
/// rule. On a clip with such levels, it reads the source of the lowest one at the origin offset,
/// so a preview never stacks; else the clip file. The window is 10 s long, or the whole clip when
/// the clip is shorter. It starts at `playhead` when it is inside the clip, else at the clip start,
/// and moves back when it would pass the clip end. It reads up to 1 s of lead-in before the start,
/// to the file start.
func previewWindow(
    of clip: ClipID, request: ClipRenderRequest, playhead: Frames, in session: Session
) throws(SessionError) -> PreviewWindow {
    guard let placed = session.clip(clip)?.clip else { throw .unknownClip(clip) }
    var source = session
    var levels = [request]
    if let rebuilt = levelRequests(request, on: session.origins(of: clip).map(\.treatment)) {
        try source.lower([clip], levels: rebuilt.lowest + 1)
        levels = rebuilt.requests
    }
    guard let lowered = source.clip(clip)?.clip else { throw .unknownClip(clip) }
    let rate = session.sampleRate
    let length = min(10 * rate, lowered.length.count)
    let wanted = lowered.offset + (placed.range.contains(playhead) ? playhead - placed.start : .zero)
    let start = Frames(min(wanted.count, (lowered.offset + lowered.length).count - length))
    let end = start + Frames(length)
    let leadIn = min(start.count, rate)
    return PreviewWindow(file: lowered.file, span: (start - Frames(leadIn))..<end, leadIn: leadIn, levels: levels)
}

/// The two loops of a window, each in two channels: a mono window plays in both.
struct PreviewAudio: Sendable {
    let result: [[Float]]
    let removed: [[Float]]
}

/// Renders `window` of `session` in `package` into memory (decision 0054): a new chain for each
/// level, bottom first, the lowest on the window of the file and each other one on the output of
/// the level below. The Result drops the lead-in; the Removed Sound is the aligned input minus the
/// Result. It writes no file, and it blocks: never call it on the main actor. `readFault` runs at
/// the block reads of the window file, by the stem of that file (tests only).
func renderPreview(
    _ window: PreviewWindow, of session: Session, in package: URL, readFault: ReadFault?, isCancelled: () -> Bool
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
    guard Int(format.channelCount) == channels, format.sampleRate == rate, opened.file.length >= span.upperBound,
        let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))
    else { throw .sourceUnreadable(file: file.path, errno: EIO) }
    var below: AVAudioPCMBuffer?
    for level in window.levels {
        // A de-clip needs the measure of the clip span, so the preview plays no de-clip.
        let chain = try EffectChain(
            level.treatment, scale: 1, rate: rate, channels: channels, component: .soundIsolation,
            repair: try RepairSetup.unmeasured(level.treatment, rate: rate, channels: channels))
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else {
            throw .engine(status: kAudio_MemFullError)
        }
        let sink = { (buffer: AVAudioPCMBuffer) throws(ClipRenderError) in append(buffer, to: output) }
        if let below {
            _ = try chain.render(below, into: sink, isCancelled: isCancelled)
        } else {
            _ = try chain.render(
                opened.file, descriptor: opened.descriptor, span: span, into: sink, file: file.path,
                stem: URL(filePath: file.path).deletingPathExtension().lastPathComponent, readFault: readFault,
                isCancelled: isCancelled, rendered: { _ in })
        }
        below = output
    }
    opened.file.framePosition = span.lowerBound
    do { try opened.file.read(into: input, frameCount: AVAudioFrameCount(count)) } catch {
        throw .sourceUnreadable(file: file.path, errno: ioErrno(of: error, file: opened.descriptor) ?? EIO)
    }
    guard let below, Int(below.frameLength) == count, Int(input.frameLength) == count else {
        throw .sourceUnreadable(file: file.path, errno: EIO)
    }
    let frames = count - window.leadIn
    var (result, removed): ([[Float]], [[Float]]) = ([], [])
    for channel in 0..<2 {
        let from = min(channel, channels - 1)
        let rendered = UnsafeBufferPointer(start: below.floatChannelData![from] + window.leadIn, count: frames)
        let source = UnsafeBufferPointer(start: input.floatChannelData![from] + window.leadIn, count: frames)
        result.append(Array(rendered))
        removed.append(vDSP.subtract(source, rendered))
    }
    return PreviewAudio(result: result, removed: removed)
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
/// `AVAudioPlayerNode`, on the system default output or in offline manual rendering, as the
/// Player. An actor, so the engine work never runs on the main actor. The node plays the window
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
    /// Gets the number of the newest call when a configuration change of the engine stops the loop.
    private let ended: @Sendable (Int) -> Void
    private(set) var graph: Graph?
    private var observer: Player.Observer?
    /// The window that the node loops, and its audio.
    private var shown: (window: PreviewWindow, audio: PreviewAudio)?
    /// Tests only: the windows that a render made.
    private(set) var windows = 0

    /// Stores values only. The engine is made at the first play.
    init(
        package: @escaping @Sendable () throws(SessionFileError) -> URL, output: Player.Output, rate: Int,
        start: @escaping @Sendable (AVAudioEngine) throws -> Void = { try $0.start() }, readFault: ReadFault? = nil,
        ended: @escaping @Sendable (Int) -> Void
    ) {
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
            let made = await renderOffActor(
                window, of: session, in: url, readFault: readFault, latest: latest, number: number)
            switch made {
            case .success(let made): audio = made
            case .failure(.cancelled): return false
            case .failure(let error): throw .clipRender(error)
            }
            windows += 1
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
        if output == .offline {
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
    _ window: PreviewWindow, of session: Session, in package: URL, readFault: ReadFault?,
    latest: OSAllocatedUnfairLock<Int>, number: Int
) async -> Result<PreviewAudio, ClipRenderError> {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            dispatchPrecondition(condition: .notOnQueue(.main))
            do throws(ClipRenderError) {
                let audio = try renderPreview(
                    window, of: session, in: package, readFault: readFault,
                    isCancelled: { latest.withLock { $0 } != number })
                continuation.resume(returning: .success(audio))
            } catch {
                continuation.resume(returning: .failure(error))
            }
        }
    }
}
