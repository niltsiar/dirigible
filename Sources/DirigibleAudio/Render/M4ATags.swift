import AVFoundation
import DirigibleCore
import Foundation

/// Copies the AAC file `source` to `output` with the iTunes atoms of `episode` (decision 0045).
/// With no chapter it is a passthrough export session, which keeps each packet and the `iTunSMPB`
/// gapless data. It reads `isCancelled()` before the first wait and every 50 ms. After
/// `cancelExport()` the pass stops within one chunk, so the wait of at most 10 s is only a limit.
/// With chapters, `copyWithChapters` writes the file and adds the chapter tracks. `chapterArtwork`
/// is the JPEG of the episode artwork for a chapter with no image; `rate` and `frames` are the
/// sample rate and the frame count of `source`. It returns true when the file gets no chapter
/// images, because a chapter has no image and there is no artwork.
@discardableResult
func tagM4A(
    _ source: URL, episode: Episode, artwork: Data?, chapters: [ExportChapter], chapterArtwork: Data?, rate: Int,
    frames: Int, to output: URL, isCancelled: () -> Bool
) throws(ExportError) -> Bool {
    // An empty episode with chapters gets no iTunes atom, as the export with no chapter (G16).
    let items = episode.isEmpty ? [] : m4aItems(episode, artwork: artwork)
    if !chapters.isEmpty {
        let images = imageSamples(chapters, artwork: chapterArtwork)
        try copyWithChapters(
            source, items: items, chapters: chapters, images: images.samples, rate: rate, frames: frames, to: output,
            isCancelled: isCancelled)
        return images.omitted
    }
    // A `.tmp` name gives -11800 with no MIME type (probe U17).
    let asset = AVURLAsset(url: source, options: [AVURLAssetOverrideMIMETypeKey: "audio/mp4"])
    guard let pass = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
        throw .writeFailed(kAudio_ParamError)
    }
    pass.metadata = items
    pass.outputURL = output
    pass.outputFileType = .m4a
    try waitCancellable(
        isCancelled: isCancelled, cancel: { pass.cancelExport() },
        start: { done in pass.exportAsynchronously { done.signal() } })
    switch pass.status {
    case .completed: return false
    case .cancelled: throw .cancelled
    default: throw .writeFailed(status(of: pass.error))
    }
}

/// Starts `work`, which signals its semaphore at the end, and waits for it. It reads
/// `isCancelled()` before the first wait and every 50 ms; on a cancel it calls `cancel`, waits at
/// most 10 s, and throws `.cancelled`.
func waitCancellable(
    isCancelled: () -> Bool, cancel: () -> Void, start work: (DispatchSemaphore) -> Void
) throws(ExportError) {
    let done = DispatchSemaphore(value: 0)
    work(done)
    repeat {
        if isCancelled() {
            cancel()
            _ = done.wait(timeout: .now() + 10)
            throw .cancelled
        }
    } while done.wait(timeout: .now() + 0.05) == .timedOut
}

func status(of error: (any Error)?) -> OSStatus {
    OSStatus(truncatingIfNeeded: (error as NSError?)?.code ?? -1)
}

/// The iTunes atoms of `episode`, with `artwork` as `covr`. M4A has no language atom (backlog).
private func m4aItems(_ episode: Episode, artwork: Data?) -> [AVMetadataItem] {
    var items: [AVMetadataItem] = []
    func add(_ key: String, _ value: (any NSCopying & NSObjectProtocol)?, type: CFString? = nil) {
        guard let value else { return }
        let item = AVMutableMetadataItem()
        item.keySpace = .iTunes
        item.key = key as NSString
        item.value = value
        if let type { item.dataType = type as String }
        items.append(item)
    }
    // The iTunes atom spec gives tves and tvsn 4 bytes, rtng and pcst 1 byte. With no type,
    // AVFoundation writes 8 bytes, which some podcast apps do not read.
    let int32 = kCMMetadataBaseDataType_SInt32
    let int8 = kCMMetadataBaseDataType_SInt8
    add("©nam", episode.title?.text as NSString?)
    add("©alb", episode.show?.text as NSString?)
    add("©ART", episode.author?.text as NSString?)
    add("aART", episode.author?.text as NSString?)
    add("tves", episode.number.map { NSNumber(value: $0.value) }, type: int32)
    add("tvsn", episode.season.map { NSNumber(value: $0.value) }, type: int32)
    add("©day", episode.date?.description as NSString?)
    add("©gen", "Podcast" as NSString)
    add("cprt", episode.copyright?.text as NSString?)
    add("rtng", episode.explicit ? NSNumber(value: 1) : nil, type: int8)
    add("desc", episode.summary?.text as NSString?)
    add("ldes", episode.notes?.text as NSString?)
    add("purl", episode.feedURL?.text as NSString?)
    add("pcst", NSNumber(value: 1), type: int8)
    add("egid", episode.guid?.text as NSString?)
    if let artwork, let name = episode.artwork {
        let item = AVMutableMetadataItem()
        item.identifier = .iTunesMetadataCoverArt
        item.value = artwork as NSData
        item.dataType = (name.isPNG ? kCMMetadataBaseDataType_PNG : kCMMetadataBaseDataType_JPEG) as String
        items.append(item)
    }
    return items
}
