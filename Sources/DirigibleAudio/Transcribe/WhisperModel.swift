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
        fileMatches(url, byteCount: byteCount, sha256: sha256) ? CheckedModel(model: self, url: url) : nil
    }

    /// `checked(at:)` on the catalog file name in `folder`.
    public func checked(in folder: URL) -> CheckedModel? { checked(at: folder.appending(path: fileName)) }
}

/// True when the file at `url` has `byteCount` bytes and the SHA-256 `sha256`: the check of each
/// file that a ggml loader reads from a folder that the user can write. A link counts with its
/// target, which the loader reads.
func fileMatches(_ url: URL, byteCount: Int, sha256: String) -> Bool {
    let target = url.resolvingSymlinksInPath()
    guard let size = try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize, size == byteCount,
        let handle = try? FileHandle(forReadingFrom: target)
    else { return false }
    defer { try? handle.close() }
    var hash = SHA256()
    while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(data: chunk) }
    return hash.finalize().map { String(format: "%02x", $0) }.joined() == sha256
}

/// A model file whose byte count and SHA-256 match the catalog: the only input of `WhisperEngine`.
/// In a release build, only `WhisperModel.checked(at:)` makes one.
public struct CheckedModel: Hashable, Sendable {
    public let model: WhisperModel
    let url: URL

    fileprivate init(model: WhisperModel, url: URL) {
        self.model = model
        self.url = url
    }

    #if DEBUG
        /// A model with no check of `url`, for the fake engine of the tests.
        static func unchecked(_ model: WhisperModel, at url: URL) -> CheckedModel {
            CheckedModel(model: model, url: url)
        }
    #endif
}
