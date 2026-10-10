import AVFoundation
import DirigibleCore
import Foundation

/// Copies the AAC file `source` to `output` with the iTunes atoms of `episode` (decision 0045).
/// The passthrough copy keeps each packet and the `iTunSMPB` gapless data. It reads
/// `isCancelled()` before the first wait and every 50 ms, and a cancel waits at most 10 s for
/// the pass to stop. This pass is the hook that run 5 replaces with a copy that adds chapters.
func tagM4A(_ source: URL, episode: Episode, to output: URL, isCancelled: () -> Bool) throws(ExportError) {
    // A `.tmp` name gives -11800 with no MIME type (probe U17).
    let asset = AVURLAsset(url: source, options: [AVURLAssetOverrideMIMETypeKey: "audio/mp4"])
    guard let pass = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
        throw .writeFailed(kAudio_ParamError)
    }
    pass.metadata = m4aItems(episode)
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

/// The iTunes atoms of `episode`. M4A has no language atom (backlog).
private func m4aItems(_ episode: Episode) -> [AVMetadataItem] {
    var items: [AVMetadataItem] = []
    func add(_ key: String, _ value: (any NSCopying & NSObjectProtocol)?) {
        guard let value else { return }
        let item = AVMutableMetadataItem()
        item.keySpace = .iTunes
        item.key = key as NSString
        item.value = value
        items.append(item)
    }
    add("©nam", episode.title?.text as NSString?)
    add("©alb", episode.show?.text as NSString?)
    add("©ART", episode.author?.text as NSString?)
    add("aART", episode.author?.text as NSString?)
    add("tves", episode.number.map { NSNumber(value: $0.value) })
    add("tvsn", episode.season.map { NSNumber(value: $0.value) })
    add("©day", episode.date?.description as NSString?)
    add("©gen", "Podcast" as NSString)
    add("cprt", episode.copyright?.text as NSString?)
    add("rtng", episode.explicit ? NSNumber(value: 1) : nil)
    add("desc", episode.summary?.text as NSString?)
    add("ldes", episode.notes?.text as NSString?)
    add("purl", episode.feedURL?.text as NSString?)
    add("pcst", NSNumber(value: 1))
    add("egid", episode.guid?.text as NSString?)
    return items
}
