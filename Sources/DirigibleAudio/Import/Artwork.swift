import DirigibleCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Why an artwork import changed nothing (decision 0045).
public enum ArtworkError: Error, Hashable, Sendable {
    /// An iCloud or File Provider item whose data is not on this Mac (decision 0040).
    case notDownloaded(file: String)
    /// The file does not open as an image.
    case unreadable(file: String)
    /// The image type is this UTI, not JPEG or PNG.
    case notJPEGOrPNG(type: String)
    case notSquare(width: Int, height: Int)
    /// The side is over `maximumArtworkSide`.
    case tooLarge(side: Int)
    /// The copy into `Artwork/` gave this errno.
    case writeFailed(Int32)
}

/// The largest side in pixels of an artwork image: the limit of Apple Podcasts (decision 0045).
public let maximumArtworkSide = 3000

/// Copies the square JPEG or PNG at `source` into `Artwork/` of `package` with a new UUID name,
/// and gives the name. It reads the type and the size from the image properties, with no decode
/// of the pixels. It writes the bytes unchanged to a dot-temporary name, flushes the file,
/// renames it with no overwrite, and flushes the folder, so an edit names only a file on the disk.
/// It never replaces a file, so undo and the backups keep their image.
public func importArtwork(
    _ source: URL, into package: URL, isDownloaded: (URL) -> Bool = sourceIsDownloaded
) throws(ArtworkError) -> ArtworkName {
    let file = source.lastPathComponent
    guard isDownloaded(source) else { throw .notDownloaded(file: file) }
    guard let image = CGImageSourceCreateWithURL(source as CFURL, nil), let type = CGImageSourceGetType(image),
        let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
        let width = properties[kCGImagePropertyPixelWidth] as? Int,
        let height = properties[kCGImagePropertyPixelHeight] as? Int
    else { throw .unreadable(file: file) }
    let png = type as String == UTType.png.identifier
    guard png || type as String == UTType.jpeg.identifier else { throw .notJPEGOrPNG(type: type as String) }
    guard width == height else { throw .notSquare(width: width, height: height) }
    guard width <= maximumArtworkSide else { throw .tooLarge(side: width) }
    guard let data = try? Data(contentsOf: source) else { throw .unreadable(file: file) }

    let folder = package.appending(path: artworkFolderName)
    if mkdir(folder.path, 0o755) != 0, errno != EEXIST { throw .writeFailed(errno) }
    let name = ArtworkName(png: png)
    let temporary = folder.appending(path: temporaryArtwork(of: name))
    let target = folder.appending(path: name.name)
    if let code = writeDurably(data, to: temporary.path) {
        unlink(temporary.path)
        throw .writeFailed(code)
    }
    guard renamex_np(temporary.path, target.path, UInt32(RENAME_EXCL)) == 0 else {
        let code = errno
        unlink(temporary.path)
        throw .writeFailed(code)
    }
    if let code = fullFlush(path: folder.path) { throw .writeFailed(code) }
    return name
}

/// Writes `data` to a new file at `path` and flushes it. Returns the errno, or nil.
private func writeDurably(_ data: Data, to path: String) -> Int32? {
    let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
    guard descriptor >= 0 else { return errno }
    defer { close(descriptor) }
    var done = 0
    while done < data.count {
        let written = data.withUnsafeBytes { write(descriptor, $0.baseAddress! + done, data.count - done) }
        if written < 0 {
            if errno == EINTR { continue }
            return errno
        }
        done += written
    }
    return fullFlush(descriptor)
}
