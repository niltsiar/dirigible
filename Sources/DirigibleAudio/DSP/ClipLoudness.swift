import AVFoundation
import DirigibleCore

/// The loudness of the frames `offset ..< offset + length` of the file of a clip, without the
/// clip gain. It opens the file with `openMedia` and reads 65 536 frames at a time.
/// - `.missing` and `.unreadable` give an empty `Loudness` and the fault.
/// - `.short` gives the loudness of the clip frames inside the file and the fault.
/// - A rate that the meter refuses gives an empty `Loudness` and no fault.
/// - A read error in the loop gives an empty `Loudness` and `.unreadable`.
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
    let empty = Loudness(blocks: [])
    guard let entry = session.files[clip.file] else { return (empty, .missing) }
    let opened = try openMedia(entry, in: package.appending(path: clipsFolderName), rate: session.sampleRate)
    guard let file = opened.file else { return (empty, opened.fault) }
    guard var meter = LoudnessMeter(sampleRate: session.sampleRate, layout: entry.layout) else { return (empty, nil) }
    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 65_536) else {
        return (empty, .unreadable)
    }
    // A short file ends the range at its last frame.
    let end = min(clip.offset.count + clip.length.count, Int(file.length))
    var position = clip.offset.count
    file.framePosition = AVAudioFramePosition(position)
    while position < end {
        if isCancelled() { throw POSIXError(.ECANCELED) }
        do { try read(file, buffer, AVAudioFrameCount(min(65_536, end - position))) } catch {
            return (empty, .unreadable)
        }
        // No frames before the end: stop, so that the loop cannot run forever.
        guard buffer.frameLength > 0 else { return (empty, .unreadable) }
        meter.feed(buffer)
        position += Int(buffer.frameLength)
        progress(position - clip.offset.count)
    }
    return (meter.result(), opened.fault)
}
