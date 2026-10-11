import DirigibleCore
import Foundation

public struct ExportOptions: Hashable, Sendable {
    public var format: ExportFormat
    public var layout: ChannelLayout
    public var rate: ExportRate
    /// Nil: no gain and no limiter.
    public var loudness: LoudnessTarget?

    public init(format: ExportFormat, layout: ChannelLayout, rate: ExportRate, loudness: LoudnessTarget? = nil) {
        self.format = format
        self.layout = layout
        self.rate = rate
        self.loudness = loudness
    }

    /// The output of `dirigible render`: 32-bit float stereo CAF at the session rate.
    public static let render = ExportOptions(format: .floatCAF, layout: .stereo, rate: .session)
}

public struct ExportResult: Hashable, Sendable {
    /// The faults of the files that the source read.
    public let faults: [FileID: MediaFault]
    /// Nil for an export with no loudness target.
    public let loudness: LoudnessReport?
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
    /// The artwork file of the episode (this path in the package) is not in the package, or it
    /// is not downloaded (decision 0045). No file was made.
    case artworkMissing(String)
    /// The cancel check was true at a chunk.
    case cancelled
}
