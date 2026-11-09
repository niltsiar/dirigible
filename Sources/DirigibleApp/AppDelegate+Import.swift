import AppKit
import UniformTypeIdentifiers

extension AppDelegate {
    /// The files that the import takes: WAV, AIFF, FLAC, MP3, and M4A (decision 0040). The open
    /// panel and a drop on the lanes or on an empty session read them.
    static let importTypes: [UTType] =
        [.wav, .aiff, .mp3, .mpeg4Audio] + [UTType(filenameExtension: "flac")].compactMap { $0 }
    /// The files of `importTypes` on a drag pasteboard, in the order of the pasteboard.
    static func audioFiles(on pasteboard: NSPasteboard) -> [URL] {
        pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true, .urlReadingContentsConformToTypes: importTypes.map(\.identifier)]
        ) as? [URL] ?? []
    }
}
