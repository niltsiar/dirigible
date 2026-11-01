import CryptoKit
import Foundation

/// The closed catalog of whisper.cpp models (decision 0065, D2), pinned at Hugging Face revision
/// 5359861c. `tinyQ51` is for the tests only: the push guard of the abort patch.
public enum WhisperModel: String, CaseIterable, Sendable {
    case base
    case smallQ51 = "small-q5_1"
    case largeV3TurboQ50 = "large-v3-turbo-q5_0"
    case tinyQ51 = "tiny-q5_1"

    public var fileName: String { "ggml-\(rawValue).bin" }

    public var byteCount: Int {
        switch self {
        case .base: 147_951_465
        case .smallQ51: 190_085_487
        case .largeV3TurboQ50: 574_041_195
        case .tinyQ51: 32_152_673
        }
    }

    public var sha256: String {
        switch self {
        case .base: "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe"
        case .smallQ51: "ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb"
        case .largeV3TurboQ50: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"
        case .tinyQ51: "818710568da3ca15689e31a743197b520007872ff9576237bda97bd1b469c3d7"
        }
    }

    public var url: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1")!
            .appending(path: fileName)
    }

    /// The file at `url` when its byte count and SHA-256 are those of this entry, else nil.
    public func checked(at url: URL) -> CheckedModel? {
        fileMatches(url, byteCount: byteCount, sha256: sha256) ? CheckedModel(source: .catalog(self), url: url) : nil
    }

    /// `checked(at:)` on the catalog file name in `folder`.
    public func checked(in folder: URL) -> CheckedModel? { checked(at: folder.appending(path: fileName)) }
}

/// True when the file at `url` has `byteCount` bytes and the SHA-256 `sha256`: the check of each
/// file that a ggml loader reads from a folder that the user can write. A link counts with its
/// target, which the loader reads.
func fileMatches(_ url: URL, byteCount: Int, sha256 expected: String) -> Bool {
    let target = url.resolvingSymlinksInPath()
    guard let size = try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize, size == byteCount else {
        return false
    }
    return (try? sha256(of: target)) == expected
}

/// The errno of a failed open or read.
struct FileReadError: Error {
    let errno: Int32
}

/// The SHA-256 of the file at `url` in lowercase hex.
func sha256(of url: URL) throws(FileReadError) -> String {
    let descriptor = open(url.path, O_RDONLY)
    guard descriptor >= 0 else { throw FileReadError(errno: errno) }
    defer { close(descriptor) }
    var hash = SHA256()
    var buffer = [UInt8](repeating: 0, count: 1 << 20)
    while true {
        let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
        if count < 0 {
            if errno == EINTR { continue }
            throw FileReadError(errno: errno)
        }
        if count == 0 { break }
        buffer.withUnsafeBytes { hash.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[..<count])) }
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}

/// The model of a transcription job: a catalog entry, or a model file of the user with the record
/// of its last passed check, if any (decision 0065, D8).
public enum WhisperModelChoice: Hashable, Sendable {
    case catalog(WhisperModel)
    case file(URL, passed: PassedModelFile?)
}

/// The SHA-256 and the facts of a model file of the user that passed the check of
/// `ModelFileCheck` (decision 0065, D8). A next check of a file with this SHA-256 runs no helper.
public struct PassedModelFile: Hashable, Sendable {
    public let sha256: String
    public let facts: WhisperModelFacts
}

/// A model file that passed its check: the only input of `WhisperEngine`. In a release build, only
/// `WhisperModel.checked(at:)` (the catalog check of D2) and `ModelFileCheck` (the user file check
/// of D8) make one.
public struct CheckedModel: Hashable, Sendable {
    /// Where the check came from.
    public enum Source: Hashable, Sendable {
        case catalog(WhisperModel)
        case file(PassedModelFile)
    }

    public let source: Source
    let url: URL

    #if DEBUG
        /// A model with no check of `url`, for the fake engine of the tests.
        static func unchecked(_ model: WhisperModel, at url: URL) -> CheckedModel {
            CheckedModel(source: .catalog(model), url: url)
        }
    #endif
}
