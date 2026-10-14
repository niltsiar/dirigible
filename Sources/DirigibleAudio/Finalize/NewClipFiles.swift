import DirigibleCore
import Foundation

/// The bytes of a 24-bit WAV of `frames` frames with `channels` channels: 3 for each sample
/// (decision 0021). The one copy of the rule.
func wavFileBytes(frames: Int64, channels: Int) -> Int64 { frames * Int64(channels) * 3 }

/// Why a batch of new clip files stopped (decision 0056). Each caller maps it to its own error.
enum NewClipFault: Error, Hashable {
    /// The batch and `diskMargin` need `needed` free bytes, and the volume has `free`.
    case space(needed: Int64, free: Int64)
    /// The `mkdir` of `Clips/` gave this errno.
    case folder(errno: Int32)
    /// The move to `file` (`<stem>.wav`) gave this errno: EEXIST when an item is at the name.
    case move(file: String, errno: Int32)
    /// The flush of the `Clips/` folder gave this errno.
    case flush(errno: Int32)
}

/// The new WAV files in `Clips/` of one edit (decision 0056): one space check, the temp names
/// `.<stem>.wav.tmp`, the stem rule of 0040, the moves with `moveNew` (never a replace), and one
/// flush of `Clips/`. The caller writes and flushes each temp, calls `commit()`, and calls
/// `discard()` in a `defer`. No code of the batch deletes a renamed file (0040): a caller that
/// must remove them reads `made`.
struct NewClipFiles: ~Copyable {
    private let package: URL
    private let flush: (String) -> Int32?
    /// The stems in add order.
    private var order: [String] = []
    /// The stems of this batch, lowercased: the `taken:` set of the stem rule.
    private(set) var stems: Set<String> = []
    /// The renamed files in commit order. A throw of `commit()` keeps them.
    private(set) var made: [URL] = []

    /// Refuses when `bytes` > 0 and `freeBytes()` < `bytes` + `diskMargin`; a batch of 0 bytes (clones
    /// only) makes no check. Then makes `Clips/`. `flush` is the test seam of a flush fault.
    init(
        in package: URL, bytes: Int64, freeBytes: () -> Int64,
        flush: @escaping (String) -> Int32? = { fullFlush(path: $0) }
    ) throws(NewClipFault) {
        if bytes > 0 {
            let free = freeBytes()
            guard free >= bytes + diskMargin else { throw .space(needed: bytes + diskMargin, free: free) }
        }
        let clips = package.appending(path: clipsFolderName)
        if mkdir(clips.path, 0o755) != 0, errno != EEXIST { throw .folder(errno: errno) }
        self.package = package
        self.flush = flush
    }

    private var clips: URL { package.appending(path: clipsFolderName) }

    /// The stem of `source` by the stem rule of 0040, with the stems of this batch taken, and its
    /// temp URL.
    mutating func add(stemOf source: URL, in session: Session) -> (stem: String, temporary: URL) {
        let stem = importStem(of: source, in: session, package: package, taken: stems)
        return (stem, add(stem: stem))
    }

    /// The temp URL of a stem that the caller planned. A stem of this batch, in any case, stops the
    /// process: two equal stems write one temp.
    mutating func add(stem: String) -> URL {
        let inserted = stems.insert(stem.lowercased()).inserted
        precondition(inserted, "Each stem of a batch is new")
        order.append(stem)
        return clips.appending(path: temporaryWAV(of: stem))
    }

    /// Moves each temp to `<stem>.wav` in add order, then flushes `Clips/` once. A throw stops at
    /// that file: the files before it stay in `made`.
    mutating func commit() throws(NewClipFault) {
        for stem in order {
            let target = clips.appending(path: "\(stem).wav")
            do throws(ExportError) {
                try moveNew(clips.appending(path: temporaryWAV(of: stem)), to: target)
            } catch {
                if case .moveFailed(let code) = error { throw .move(file: "\(stem).wav", errno: code) }
                throw .move(file: "\(stem).wav", errno: EEXIST)
            }
            made.append(target)
        }
        if let code = flush(clips.path) { throw .flush(errno: code) }
    }

    /// Unlinks each temp that `commit()` did not move.
    func discard() {
        for stem in order.dropFirst(made.count) { unlink(clips.appending(path: temporaryWAV(of: stem)).path) }
    }
}

extension ImportError {
    /// The import error of `fault` for the source file `file`.
    init(_ fault: NewClipFault, file: String) {
        switch fault {
        case .space(let needed, let free): self = .space(file: file, needed: needed, free: free)
        case .folder(let code), .flush(let code):
            self = .write(file: file, .writeFailed(file: clipsFolderName, status: code))
        case .move(let name, let code):
            self = .write(file: file, .writeFailed(file: "\(clipsFolderName)/\(name)", status: code))
        }
    }
}

extension PasteError {
    init(_ fault: NewClipFault) {
        switch fault {
        case .space(let needed, let free): self = .space(needed: needed, free: free)
        case .folder(let code), .flush(let code): self = .write(file: clipsFolderName, errno: code)
        case .move(let name, let code): self = .write(file: name, errno: code)
        }
    }
}
