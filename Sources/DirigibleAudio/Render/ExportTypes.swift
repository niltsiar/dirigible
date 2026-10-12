import DirigibleCore
import Foundation

public struct ExportOptions: Hashable, Sendable {
    public var format: ExportFormat
    public var layout: ChannelLayout
    public var rate: ExportRate
    /// Nil: no gain and no limiter.
    public var loudness: LoudnessTarget?
    /// The title of the chapter that an M4A export adds at the range start when the episode has no
    /// title and no show name. Only `DirigibleApp` reads `L10n` (decision 0010), so the app gives
    /// its text here; the CLI and MCP keep the English default.
    public var introTitle: String

    public init(
        format: ExportFormat, layout: ChannelLayout, rate: ExportRate, loudness: LoudnessTarget? = nil,
        introTitle: String = "Intro"
    ) {
        self.format = format
        self.layout = layout
        self.rate = rate
        self.loudness = loudness
        self.introTitle = introTitle
    }

    /// The output of `dirigible render`: 32-bit float stereo CAF at the session rate.
    public static let render = ExportOptions(format: .floatCAF, layout: .stereo, rate: .session)
}

public struct ExportResult: Hashable, Sendable {
    /// The faults of the files that the source read.
    public let faults: [FileID: MediaFault]
    /// Nil for an export with no loudness target.
    public let loudness: LoudnessReport?
    /// The chapters of the range that the file does not have, because each starts at the time of
    /// the chapter before it. Empty for a format with no chapters.
    public let droppedChapters: [Marker]
    /// The M4A has chapters with an image and chapters with none, and the episode has no artwork, so
    /// the file has no chapter images.
    public let chapterImagesOmitted: Bool
}

public enum ExportError: Error, Hashable, Sendable {
    /// An item is at the target. It did not change.
    case exists
    /// AAC at a file rate above 48 kHz (probe P5), or MP3 at a file rate other than 32, 44.1, or
    /// 48 kHz (decision 0034). No file was made.
    case rateNotSupported(Int)
    /// A create, format, write, or close of the file gave this status.
    case writeFailed(OSStatus)
    /// The move to the target gave this errno.
    case moveFailed(Int32)
    /// A write gave -40 with errno ENOSPC (probe P8).
    case diskFull
    /// An audio file did not open because the process had no free descriptor (this errno).
    case openFailed(Int32)
    /// The package source threw: the lock lost the package.
    case packageUnavailable
    /// The artwork file of the episode (this path in the package) is not in the package, it is
    /// not downloaded (decision 0045), or a PNG of an M4A export does not decode. No file was made.
    case artworkMissing(String)
    /// The image file of this chapter is not in the package, it is not downloaded, or a PNG of an
    /// M4A export does not decode. `rate` is the session rate of its position. No file was made.
    case chapterImageMissing(Marker, rate: Int)
    /// The cancel check was true at a chunk.
    case cancelled
    /// The range of an MP3 export has this count of chapters, over `maximumChapters`. No file was
    /// made.
    case tooManyChapters(Int)
    /// The ID3 tag of an MP3 export is over `maximumTagSize` bytes. No file was made.
    case tagTooLarge
    /// The range of an MP3 export with chapters is over `maximumChapterMilliseconds`, the last
    /// time of an ID3 chapter. No file was made.
    case chaptersTooLong
}

extension ExportError {
    /// The error of a failed atomic write of a small file. Foundation gives the POSIX errno under
    /// the CocoaError (probe-errno of run 2026-10-09-chapters-export). ENOSPC is a full disk.
    /// Another errno came from the temporary file or the rename, so it is `.moveFailed`. An error
    /// with no POSIX cause gives EIO. No errno goes into `.writeFailed`, which holds an OSStatus.
    init(writing error: any Error) {
        guard let cause = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError,
            cause.domain == NSPOSIXErrorDomain
        else {
            self = .moveFailed(EIO)
            return
        }
        self = cause.code == Int(ENOSPC) ? .diskFull : .moveFailed(Int32(cause.code))
    }
}
