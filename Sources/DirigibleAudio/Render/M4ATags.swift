import AVFoundation
import DirigibleCore
import Foundation

/// Copies the AAC file `source` to `output` with the iTunes atoms of `episode` (decision 0045).
/// The passthrough copy keeps each packet and the `iTunSMPB` gapless data. It reads
/// `isCancelled()` before the first wait and every 50 ms. After `cancelExport()` the pass stops
/// within one chunk, so the wait of at most 10 s is only a limit. This pass is the hook that run 5
/// replaces with a copy that adds chapters.
func tagM4A(
    _ source: URL, episode: Episode, artwork: Data?, to output: URL, isCancelled: () -> Bool
) throws(ExportError) {
    // A `.tmp` name gives -11800 with no MIME type (probe U17).
    let asset = AVURLAsset(url: source, options: [AVURLAssetOverrideMIMETypeKey: "audio/mp4"])
    guard let pass = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
        throw .writeFailed(kAudio_ParamError)
    }
    pass.metadata = m4aItems(episode, artwork: artwork)
    pass.outputURL = output
    pass.outputFileType = .m4a
    let done = DispatchSemaphore(value: 0)
    pass.exportAsynchronously { done.signal() }
    repeat {
        if isCancelled() {
            pass.cancelExport()
            _ = done.wait(timeout: .now() + 10)
            throw .cancelled
        }
    } while done.wait(timeout: .now() + 0.05) == .timedOut
    switch pass.status {
    case .completed: return
    case .cancelled: throw .cancelled
    default: throw .writeFailed(OSStatus(truncatingIfNeeded: (pass.error as NSError?)?.code ?? -1))
    }
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
