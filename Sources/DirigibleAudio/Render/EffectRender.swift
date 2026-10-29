import AVFoundation
import DirigibleCore
import Foundation

/// Why a clip render changed nothing (decision 0054). Each `file` is a path in `Clips/`.
public enum ClipRenderError: Error, Hashable, Sendable {
    /// The new files and the 1 GB margin need `needed` free bytes, and the volume has `free`.
    case space(needed: Int64, free: Int64)
    /// `Clips/` or a new file cannot be made, written, flushed, or renamed, with the errno or the
    /// status.
    case write(file: String, errno: Int32)
    /// A source WAV does not read, with its errno: EIO when its format is not the format of its
    /// pool file or when it gives fewer frames than its run.
    case sourceUnreadable(file: String, errno: Int32)
    /// A source WAV is not in `Clips/`.
    case sourceMissing(file: String)
    /// The data of a source WAV is not on this Mac.
    case notDownloaded(file: String)
    case cancelled
    /// The session refused the render: for example a transcript that did not load.
    case session(SessionError)
    /// The treatment does not take a clip on a track with this role (`Treatment.accepts`).
    case trackRole(clip: ClipID, role: Track.Role)
    /// The clips of one run, which one new file holds, come from groups with different treatments.
    case mixedTreatments(clips: [ClipID])
    /// The effect unit did not load, with the status of the load: -3000 (`invalidComponentID`)
    /// when no component matches.
    case effectUnavailable(status: Int32)
    /// The engine did not render, with its error code or its manual rendering status.
    case engine(status: Int32)
    /// The second pass of the new WAV `file` still peaks at a 24-bit end code.
    case stillOverFullScale(file: String)
    /// A filter corner `hertz` (a rumble or a de-ess) is at or over 0.45 x the session rate
    /// (decision 0064 D9).
    case cornerTooHigh(hertz: Int, limit: CornerLimit)
    /// A rendered block of the new WAV `file` holds a NaN or an infinity.
    case nonFiniteSample(file: String)

    /// The bound that a refused corner names: the highest whole Hz that the session rate takes, or,
    /// when no value of the effect fits, the lowest session rate in Hz that takes the effect.
    public enum CornerLimit: Hashable, Sendable {
        case hertz(Int)
        case lowestRate(Int)
    }
}

/// The de-clip result of a clip (decision 0064 D4): the clipped runs that the render filled in its
/// run, and the dB that the scales of the render took off its level, 20 log10(1 / (s1 x s2)).
package struct ClipRepair: Hashable, Sendable {
    package let runs: Int
    package let levelDrop: Double
}

/// The session of a clip render, the WAVs that it renamed, each moved clip with its new file, each
/// clip that needed no render (decision 0057), and the de-clip result of each clip of a run with a
/// de-clip (decision 0064).
package struct ClipRenderOutcome: Sendable {
    package let session: Session
    package let made: [URL]
    package let clips: [RenderedClip]
    package let unchanged: [ClipID]
    package var repairs: [ClipID: ClipRepair] = [:]
}

/// Renders the clips of each group through the effects of its treatment into new WAVs in
/// `Clips/` (decision 0054): one WAV for each run of `clipRuns(of:)` over the clips of all groups,
/// and `Session.repoint` onto them. A run whose clips have two treatments throws
/// `.mixedTreatments`. It never writes `session.xml`, and it blocks: never call it on the main actor.
///
/// The order: the runs, the role check of each clip (`Treatment.accepts`) with the corner check of
/// each run (`RepairSetup.check`), the source checks, one space check (`freeBytes`) for `bytes`, or
/// for the bytes of the runs when it is nil, the stems "<source stem> NR" (" HR", " RP") by the stem
/// rule of 0040, `repoint` on a session copy with 0 dB, the measure step of each run with a repair
/// kind (`repairSetup`, which reads only for a de-clip), the unit load, then each run through a new
/// chain into `.<stem>.wav.tmp` at the scale s1 of its setup, with a second pass at s1 x s2 when its
/// peak is over full scale (`.stillOverFullScale` when the second pass still peaks at the largest
/// 24-bit sample), the read-back, `repoint` on the input session with the dB of each second-pass
/// scale s2 as the added gain of its run (decision 0057), or 0 dB for a run with a de-clip, whose
/// scales stay a level loss (decision 0064 D4), the renames, and one flush of `Clips/`
/// (`NewClipFiles`). Each block goes through `RepairSetup.checkFinite` before its write. So a
/// refusal that the values or the free space decide reads no audio and writes no file, and a throw
/// before the renames leaves no new file. A fault in the
/// renames keeps the renamed WAVs as unused files (0040), and a cancel after them removes them
/// (`removeMadeFiles`). `isCancelled` is read before each run, each block, and the renames, and
/// after them. `progress` rises by 0.1 % or more at each step, holds during a second pass, and gives 1
/// only after the read-back of the last run. `readFault` runs at the block reads of the run of the
/// new stem that it names (tests and `CaptureEnvironment.clipRenderRead`).
/// `secondPassGain` multiplies the scale of a second pass (tests only: a unit that renders louder
/// the second time), and `addedStage` runs after the post-stages of each chain (tests only: a stage
/// that renders louder or not finite). The one caller outside tests is `renderLevels`, behind
/// `renderRequest`.
func renderClips(
    _ groups: [(clips: [ClipID], treatment: Treatment)], of session: Session, in package: URL,
    bytes: Int64? = nil, freeBytes: () -> Int64,
    component: (Int) -> AudioComponentDescription = { _ in .soundIsolation },
    readFault: ReadFault? = nil, isDownloaded: (URL) -> Bool = sourceIsDownloaded,
    progress: @escaping (Double) -> Void = { _ in }, isCancelled: @escaping () -> Bool = { false },
    secondPassGain: Float = 1, addedStage: (any RenderStage)? = nil
) throws(ClipRenderError) -> ClipRenderOutcome {
    // `repoint` takes the runs of all clips, so the runs come from the clips of all groups at once.
    let named = groups.flatMap { group in group.clips.map { (clip: $0, treatment: group.treatment) } }
    let found: [ClipRun]
    do throws(SessionError) { found = try session.clipRuns(of: named.map(\.clip)) } catch { throw .session(error) }
    var runs: [(run: ClipRun, source: AudioFile, treatment: Treatment)] = []
    for run in found {
        let members = Set(run.clips)
        let treatments = Set(named.filter { members.contains($0.clip) }.map(\.treatment))
        guard treatments.count == 1, let treatment = treatments.first else {
            throw .mixedTreatments(clips: run.clips)
        }
        guard let source = session.files[run.file] else { throw .session(.unknownFile(run.file)) }
        runs.append((run, source, treatment))
    }
    for (run, _, treatment) in runs {
        try treatment.checkRoles(of: run.clips, in: session)
        try RepairSetup.check(treatment, rate: session.sampleRate)
    }
    for (_, source, _) in runs {
        let url = sourceURL(source, in: package)
        guard access(url.path, F_OK) == 0 else {
            let code = errno
            throw code == ENOENT ? .sourceMissing(file: source.path) : .sourceUnreadable(file: source.path, errno: code)
        }
        guard isDownloaded(url) else { throw .notDownloaded(file: source.path) }
    }
    guard !runs.isEmpty else { return ClipRenderOutcome(session: session, made: [], clips: [], unchanged: []) }
    let rate = Double(session.sampleRate)
    let frames = runs.map { Int64(($0.run.span.upperBound - $0.run.span.lowerBound).count) }
    let needed =
        bytes
        ?? zip(runs, frames).reduce(Int64(0)) {
            $0 + wavFileBytes(frames: $1.1, channels: $1.0.source.layout.channelCount)
        }
    var files: NewClipFiles
    do throws(NewClipFault) {
        files = try NewClipFiles(in: package, bytes: needed, freeBytes: freeBytes)
    } catch {
        throw ClipRenderError(error)
    }
    defer { files.discard() }
    var stems: [String] = []
    var temporaries: [URL] = []
    for (_, source, treatment) in runs {
        let stem = importStems(
            of: URL(filePath: source.path), suffixes: [treatment.suffix], in: session, package: package,
            taken: files.stems)[0]
        do throws(NewClipFault) { temporaries.append(try files.add(stem: stem)) } catch { throw ClipRenderError(error) }
        stems.append(stem)
    }
    func renderedRuns(_ gains: [Gain]) -> [RenderedRun] {
        zip(runs, zip(stems, gains)).map {
            RenderedRun(run: $0.run, stem: $1.0, treatment: $0.treatment, addedGain: $1.1)
        }
    }
    let clips: [RenderedClip]
    do throws(SessionError) {
        var checked = session
        clips = try checked.repoint(renderedRuns(runs.map { _ in .zero }))
    } catch {
        throw .session(error)
    }
    // The source WAV of `source`, checked against its run, open for reading.
    func openSource(_ source: AudioFile, channels: Int, span: Range<AVAudioFramePosition>) throws(ClipRenderError)
        -> (descriptor: Int32, file: AVAudioFile)
    {
        let opened: (descriptor: Int32, file: AVAudioFile)
        do throws(ImportError) {
            opened = try openAudio(sourceURL(source, in: package))
        } catch {
            throw ClipRenderError(error, source: source.path)
        }
        let format = opened.file.fileFormat
        guard Int(format.channelCount) == channels, format.sampleRate == rate, opened.file.length >= span.upperBound
        else {
            close(opened.descriptor)
            throw .sourceUnreadable(file: source.path, errno: EIO)
        }
        return opened
    }
    let spans = runs.map {
        AVAudioFramePosition($0.run.span.lowerBound.count)..<AVAudioFramePosition($0.run.span.upperBound.count)
    }
    var setups: [RepairSetup] = []
    for (index, (_, source, treatment)) in runs.enumerated() {
        let channels = source.layout.channelCount
        var setup: RepairSetup
        if treatment.declip != nil {
            let opened = try openSource(source, channels: channels, span: spans[index])
            defer { close(opened.descriptor) }
            setup = try repairSetup(
                span: spans[index], of: opened.file, descriptor: opened.descriptor, treatment: treatment,
                file: source.path, stem: stems[index], readFault: readFault, isCancelled: isCancelled)
        } else {
            setup = try RepairSetup.unmeasured(treatment, rate: rate, channels: channels)
        }
        if let addedStage { setup.post.append(addedStage) }
        setups.append(setup)
    }
    // The first run of each channel count loads its chain here, so a load failure of any layout
    // throws before the first write.
    var loaded: [Int: EffectChain] = [:]
    var counts: Set<Int> = []
    for (index, (_, source, treatment)) in runs.enumerated() where counts.insert(source.layout.channelCount).inserted {
        let channels = source.layout.channelCount
        loaded[index] = try EffectChain(
            treatment, scale: setups[index].scale, rate: rate, channels: channels, component: component(channels),
            repair: setups[index])
    }

    let total = Double(frames.reduce(0, +))
    var done: Int64 = 0
    var reported = 0.0
    var addedGains = runs.map { _ in Gain.zero }
    var repairs: [ClipID: ClipRepair] = [:]
    for (index, (run, source, treatment)) in runs.enumerated() {
        guard !isCancelled() else { throw .cancelled }
        let channels = source.layout.channelCount
        let span = spans[index]
        let opened = try openSource(source, channels: channels, span: span)
        defer { close(opened.descriptor) }
        let wav = "\(clipsFolderName)/\(stems[index]).wav"
        func pass(_ scale: Float, progress: (Int) -> Void) throws(ClipRenderError) -> (length: Int, peak: Float) {
            let chain: EffectChain
            if let ready = loaded.removeValue(forKey: index) {
                chain = ready
            } else {
                chain = try EffectChain(
                    treatment, scale: scale, rate: rate, channels: channels, component: component(channels),
                    repair: setups[index])
            }
            let writer: ClipWriter
            do throws(FinalizeError) {
                writer = try ClipWriter(url: temporaries[index], file: wav, format: opened.file.processingFormat)
            } catch {
                throw ClipRenderError(error, wav: wav)
            }
            let result = try chain.render(
                opened.file, descriptor: opened.descriptor, span: span,
                into: { buffer throws(ClipRenderError) in
                    try RepairSetup.checkFinite(buffer, file: wav)
                    do throws(FinalizeError) { try writer.write(buffer) } catch {
                        throw ClipRenderError(error, wav: wav)
                    }
                }, file: source.path, stem: stems[index], readFault: readFault, isCancelled: isCancelled,
                rendered: progress)
            do throws(FinalizeError) { try writer.close() } catch { throw ClipRenderError(error, wav: wav) }
            return result
        }
        let base = Double(done)
        var scale = setups[index].scale
        var result = try pass(scale) { written in
            let fraction = (base + Double(written)) / total
            // A rise of less than 0.1 % is not reported: each call can make a main-actor task.
            guard fraction < 1, fraction - reported >= 0.001 else { return }
            reported = fraction
            progress(fraction)
        }
        if let second = fullScaleRepair(result.peak) {
            result = try pass(scale * second * secondPassGain) { _ in }
            guard result.peak < largestSample else { throw .stillOverFullScale(file: wav) }
            scale *= second
            if treatment.declip == nil, let added = Gain(clamping: -20 * log10(Double(second))) {
                addedGains[index] = added
            }
        }
        if treatment.declip != nil {
            for clip in run.clips {
                repairs[clip] = ClipRepair(runs: setups[index].runs, levelDrop: 20 * log10(1 / Double(scale)))
            }
        }
        guard result.length == span.count, try readBack(temporaries[index], wav: wav) == span.count else {
            throw .sourceUnreadable(file: source.path, errno: EIO)
        }
        done += Int64(span.count)
    }
    var rendered = session
    do throws(SessionError) { _ = try rendered.repoint(renderedRuns(addedGains)) } catch { throw .session(error) }
    progress(1)
    guard !isCancelled() else { throw .cancelled }
    do throws(NewClipFault) { try files.commit() } catch { throw ClipRenderError(error) }
    guard !isCancelled() else {
        removeMadeFiles(files.made)
        throw .cancelled
    }
    return ClipRenderOutcome(session: rendered, made: files.made, clips: clips, unchanged: [], repairs: repairs)
}

/// The scale that puts the peak `peak` at the import ceiling, two 24-bit steps under full scale,
/// or nil at full scale or under. A peak over full scale saturates in 24 bits (A11 of import), so a
/// second pass renders at this scale, and the clip gain gives the level back, except for a run with
/// a de-clip (decision 0064 D4). The measure step takes it for s1 of a filled peak.
func fullScaleRepair(_ peak: Float) -> Float? {
    peak > 1 ? Float((1 - 0x1p-22) / Double(peak)) : nil
}

/// The largest sample of a 24-bit WAV, 1 - 2^-23: a sample at it or over can be a clipped one.
private let largestSample: Float = 0x1.fffffcp-1

/// Flushes the WAV at `url` and gives its frame count as it reads back.
private func readBack(_ url: URL, wav: String) throws(ClipRenderError) -> Int {
    let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
    guard descriptor >= 0 else { throw .write(file: wav, errno: errno) }
    defer { close(descriptor) }
    if let code = fullFlush(descriptor) { throw .write(file: wav, errno: code) }
    do {
        return Int(try AVAudioFile(forReading: url).length)
    } catch {
        throw .write(file: wav, errno: ioErrno(of: error, file: descriptor) ?? EIO)
    }
}

/// The URL of the WAV of `file` in `Clips/` of `package`.
private func sourceURL(_ file: AudioFile, in package: URL) -> URL {
    package.appending(path: "\(clipsFolderName)/\(file.path)")
}

extension ClipRenderError {
    /// The render error of an `openAudio` refusal of the source WAV at the pool path `source`.
    init(_ error: ImportError, source: String) {
        switch error {
        case .unreadable(_, let code):
            self = code == ENOENT ? .sourceMissing(file: source) : .sourceUnreadable(file: source, errno: code)
        case .notAudio, .notDownloaded, .tooManyChannels, .space, .cancelled, .write, .session:
            self = .sourceUnreadable(file: source, errno: EIO)
        }
    }
}
