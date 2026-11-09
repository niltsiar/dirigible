import AVFoundation
import DirigibleCore

/// The loudness of the frames `offset ..< offset + length` of the file of a clip, without the
/// clip gain. It opens the file with `openMedia` and reads 65 536 frames at a time.
/// - `.missing` and `.unreadable` give an empty `Loudness` and the fault.
/// - `.short` gives the loudness of the clip frames inside the file and the fault.
/// - A rate that the meter refuses gives an empty `Loudness` and no fault.
/// - A read error in the loop, or a NaN or an infinity, gives an empty `Loudness` and `.unreadable`.
/// It reads the disk, so never call it on the main actor. It throws when the process has no free
/// descriptor (EMFILE or ENFILE), as `checkMedia`, and ECANCELED when `isCancelled`, read before
/// each block, gives true. `progress` gets the clip frames done after each block.
public func clipLoudness(
    _ clip: Clip, in session: Session, package: URL, progress: (Int) -> Void = { _ in },
    isCancelled: () -> Bool = { false }
) throws(POSIXError) -> (loudness: Loudness, fault: MediaFault?) {
    try clipLoudness(clip, in: session, package: package, progress: progress, isCancelled: isCancelled) {
        try $0.read(into: $1, frameCount: $2)
    }
}

/// The loudness of each clip of `clips`, in order (decision 0049). It reads `isCancelled` before
/// the first `progress`. The fraction of `progress` is the frames done over the frames of all
/// clips, so it grows in one count over the clips.
public func clipsLoudness(
    _ clips: [Clip], in session: Session, package: URL, progress: (Double) -> Void = { _ in },
    isCancelled: () -> Bool = { false }
) throws(POSIXError) -> [(loudness: Loudness, fault: MediaFault?)] {
    if isCancelled() { throw POSIXError(.ECANCELED) }
    progress(0)
    let total = Double(max(1, clips.reduce(0) { $0 + $1.length.count }))
    var done = 0
    var measured: [(loudness: Loudness, fault: MediaFault?)] = []
    for clip in clips {
        let before = done
        measured.append(
            try clipLoudness(
                clip, in: session, package: package, progress: { progress(Double(before + $0) / total) },
                isCancelled: isCancelled))
        done += clip.length.count
        progress(Double(done) / total)
    }
    return measured
}

/// `clipLoudness` with the read of one block as a parameter, so that a test can give a read that
/// fails.
func clipLoudness(
    _ clip: Clip, in session: Session, package: URL, progress: (Int) -> Void = { _ in },
    isCancelled: () -> Bool = { false }, read: (AVAudioFile, AVAudioPCMBuffer, AVAudioFrameCount) throws -> Void
) throws(POSIXError) -> (loudness: Loudness, fault: MediaFault?) {
    let (meter, fault) = try meterRead(
        clip.file, frames: clip.offset..<(clip.offset + clip.length), in: session, package: package, keepsSteps: false,
        progress: progress, isCancelled: isCancelled, read: read)
    return (meter?.result() ?? Loudness(blocks: []), fault)
}

/// The frames `frames` of the pool file `file` through one new `LoudnessMeter`, in blocks of
/// 65 536 frames: the block read of `clipLoudness`. The meter is nil for a missing file, a file
/// that does not open, a failed read, and (with no fault) a rate that the meter refuses. A short
/// file gives the meter of its frames inside `frames` and `.short`; a NaN or an infinity gives
/// the meter and `.unreadable`. The throws and `progress` (the frames done) are those of
/// `clipLoudness`.
func meterRead(
    _ file: FileID, frames: Range<Frames>, in session: Session, package: URL, keepsSteps: Bool,
    progress: (Int) -> Void, isCancelled: () -> Bool,
    read: (AVAudioFile, AVAudioPCMBuffer, AVAudioFrameCount) throws -> Void
) throws(POSIXError) -> (meter: LoudnessMeter?, fault: MediaFault?) {
    guard let entry = session.files[file] else { return (nil, .missing) }
    let opened = try openMedia(entry, in: package.appending(path: clipsFolderName), rate: session.sampleRate)
    guard let audio = opened.file else { return (nil, opened.fault) }
    guard var meter = LoudnessMeter(sampleRate: session.sampleRate, layout: entry.layout, keepsSteps: keepsSteps)
    else { return (nil, nil) }
    guard let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 65_536) else {
        return (nil, .unreadable)
    }
    // A short file ends the range at its last frame.
    let end = min(frames.upperBound.count, Int(audio.length))
    var position = frames.lowerBound.count
    audio.framePosition = AVAudioFramePosition(position)
    while position < end {
        if isCancelled() { throw POSIXError(.ECANCELED) }
        do { try read(audio, buffer, AVAudioFrameCount(min(65_536, end - position))) } catch {
            return (nil, .unreadable)
        }
        // No frames before the end: stop, so that the loop cannot run forever.
        guard buffer.frameLength > 0 else { return (nil, .unreadable) }
        meter.feed(buffer)
        position += Int(buffer.frameLength)
        progress(position - frames.lowerBound.count)
    }
    return (meter, meter.nonFinite ? .unreadable : opened.fault)
}
