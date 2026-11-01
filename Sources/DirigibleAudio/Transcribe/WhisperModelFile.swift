import Foundation

/// Why a model file of the user does not pass `WhisperModelFile.read(_:)`. A reason names the field
/// and its value, for example "n_text_head 0": a text inside a localized sentence, as an errno.
public enum ModelFileError: Error, Hashable, Sendable {
    /// No ggml magic in the first 4 bytes.
    case notWhisperModel
    /// A ggml file with values that the vendored whisper.cpp cannot run safely.
    case unsupported(String)
    /// The file ends before the end of its last part.
    case truncated
    /// A part has a value that no whisper.cpp writer gives.
    case damaged(String)
    /// The open or a read failed with this errno.
    case unreadable(errno: Int32)
}

/// The model sizes of whisper.cpp, from the encoder layer count.
public enum WhisperModelKind: Hashable, Sendable {
    case tiny, base, small, medium, large

    /// Nil for a layer count that no OpenAI model has.
    init?(audioLayers: Int) {
        switch audioLayers {
        case 4: self = .tiny
        case 6: self = .base
        case 12: self = .small
        case 24: self = .medium
        case 32: self = .large
        default: return nil
        }
    }
}

/// The facts of a model file that the sheet and the job read.
public struct WhisperModelFacts: Hashable, Sendable, Codable {
    public let audioLayers: Int
    public let textLayers: Int
    public let melCount: Int
    /// False for an English-only file (n_vocab 51,864): whisper.cpp pushes no language token for it.
    public let isMultilingual: Bool

    public var kind: WhisperModelKind? { WhisperModelKind(audioLayers: audioLayers) }
}

/// A ggml whisper model file of the user that the vendored whisper.cpp can load with no process
/// death (decision 0065, D8): the boundary type of a user model file. `read(_:)` keeps the input
/// classes that end the process in the loader or in `whisper_full`: the hparams, the ftype, the mel
/// filter size, the vocabulary, and the tensor headers. The loader refuses an unknown tensor name,
/// a wrong shape, and a wrong size with a null context, so the parse holds no name table.
public struct WhisperModelFile: Hashable, Sendable {
    public let facts: WhisperModelFacts
    /// The ftype field with its quantization version, for example 1009 for Q5_1.
    public let ftype: Int32
    public let byteCount: Int

    static let magic: UInt32 = 0x6767_6d6c
    /// The (width, head count) pairs of the OpenAI models, tiny to large.
    static let headsOfWidth: [Int32: Int32] = [384: 6, 512: 8, 768: 12, 1024: 16, 1280: 20]
    /// English-only, multilingual, and large-v3 (one more language).
    static let vocabularySizes: ClosedRange<Int32> = 51_864...51_866
    static let layerCounts: ClosedRange<Int32> = 1...32
    static let melCounts: Set<Int32> = [80, 128]
    static let audioContext: Int32 = 1_500
    static let textContext: Int32 = 448
    /// The mel worker of whisper.cpp asserts this filter width.
    static let fftBins: Int32 = 201
    /// ftype % 1000 values that `ggml_ftype_to_ggml_type` maps; another value asserts before the
    /// error branch of the loader.
    static let ftypes: Set<Int32> = [0, 1, 2, 3, 7, 8, 9, 10, 11, 12, 13, 14]
    static let maxNameLength: Int32 = 64
    static let positionalName = "decoder.positional_embedding"

    /// Bytes and values per block of each tensor type that an ftype of `ftypes` gives.
    static let blockOfType: [Int32: (bytes: Int, values: Int)] = [
        0: (4, 1), 1: (2, 1), 2: (18, 32), 3: (20, 32), 6: (22, 32), 7: (24, 32), 8: (34, 32),
        10: (84, 256), 11: (110, 256), 12: (144, 256), 13: (176, 256), 14: (210, 256),
    ]

    /// Reads the file with seeks. Of the tensor data, it reads only `decoder.positional_embedding`
    /// (at most 2,293,760 bytes): a NaN or an infinite value in a row that a short trial does not
    /// reach ends a longer job.
    public static func read(_ url: URL) throws(ModelFileError) -> WhisperModelFile {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw .unreadable(errno: errno) }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw .unreadable(errno: errno) }
        var reader = Reader(descriptor: descriptor, size: Int(status.st_size))

        guard reader.size >= 4, UInt32(bitPattern: try reader.int32()) == magic else { throw .notWhisperModel }
        let header = try Header(&reader)
        try header.check()

        let melCount = try reader.int32()
        let fftBins = try reader.int32()
        guard melCount == header.melCount else { throw .unsupported("mel filter count \(melCount)") }
        guard fftBins == Self.fftBins else { throw .unsupported("n_fft \(fftBins)") }
        try reader.skip(Int(melCount) * Int(fftBins) * 4)

        try readVocabulary(&reader, size: header.vocabularySize)
        try readTensors(&reader, header: header)
        return WhisperModelFile(
            facts: WhisperModelFacts(
                audioLayers: Int(header.audioLayers), textLayers: Int(header.textLayers),
                melCount: Int(header.melCount), isMultilingual: header.vocabularySize >= 51_865),
            ftype: header.ftype, byteCount: reader.size)
    }

    /// A count of 1 to n_vocab and a one-byte token " ": `whisper_full` asserts on a smaller count
    /// and throws on a missing " ".
    private static func readVocabulary(_ reader: inout Reader, size: Int32) throws(ModelFileError) {
        let count = try reader.int32()
        guard (1...size).contains(count) else { throw .damaged("vocabulary count \(count)") }
        var hasSpace = false
        for _ in 0..<count {
            let length = Int(UInt32(bitPattern: try reader.int32()))
            if length == 1 {
                if try reader.take(1).first == 0x20 { hasSpace = true }
            } else {
                try reader.skip(length)
            }
        }
        guard hasSpace else { throw .damaged("no token \" \"") }
    }

    /// Walks each tensor header to the end of the file: each name once, the data size from the
    /// dimensions and the type. The loader reads 12 header bytes before its end-of-file check, so
    /// fewer than 12 bytes after the last tensor are extra bytes.
    private static func readTensors(_ reader: inout Reader, header: Header) throws(ModelFileError) {
        guard reader.offset < reader.size else { throw .truncated }
        var names = Set<[UInt8]>()
        var positional = false
        while reader.offset < reader.size {
            let left = reader.size - reader.offset
            guard left >= 12 else { throw .damaged("bytes after the last tensor: \(left)") }
            let dimensionCount = try reader.int32()
            let nameLength = try reader.int32()
            let type = try reader.int32()
            guard (1...4).contains(dimensionCount) else { throw .damaged("dimension count \(dimensionCount)") }
            guard (1...maxNameLength).contains(nameLength) else { throw .damaged("name length \(nameLength)") }
            var dimensions: [Int] = []
            for _ in 0..<dimensionCount { dimensions.append(Int(try reader.int32())) }
            let nameBytes = Array(try reader.take(Int(nameLength)))
            let name = String(decoding: nameBytes, as: UTF8.self)
            guard let block = blockOfType[type] else { throw .damaged("tensor type \(type) of \(name)") }
            guard dimensions.allSatisfy({ $0 >= 1 }) else { throw .damaged("dimensions \(dimensions) of \(name)") }
            guard dimensions[0] % block.values == 0 else {
                throw .damaged("row of \(dimensions[0]) values of type \(type) in \(name)")
            }
            guard names.insert(nameBytes).inserted else { throw .damaged("tensor \(name) twice") }
            guard let elements = product(dimensions), let byteCount = product([elements / block.values, block.bytes])
            else { throw .damaged("dimensions \(dimensions) of \(name)") }
            guard name == positionalName else {
                try reader.skip(byteCount)
                continue
            }
            guard type == 0, dimensions == [Int(header.textWidth), Int(header.textContext)] else {
                throw .damaged("\(name) of type \(type) and dimensions \(dimensions)")
            }
            let values = try reader.take(byteCount)
            let finite = values.withUnsafeBytes { raw in
                (0..<elements).allSatisfy { raw.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self).isFinite }
            }
            guard finite else { throw .damaged("NaN or infinite value in \(name)") }
            positional = true
        }
        guard positional else { throw .damaged("no \(positionalName)") }
    }

    /// Nil when the product does not fit in an `Int`.
    private static func product(_ values: [Int]) -> Int? {
        var result = 1
        for value in values {
            let (next, overflow) = result.multipliedReportingOverflow(by: value)
            if overflow { return nil }
            result = next
        }
        return result
    }
}

extension WhisperModelFile {
    /// The 11 int32 hparams after the magic, in file order.
    struct Header {
        let vocabularySize, audioContext, audioWidth, audioHeads, audioLayers: Int32
        let textContext, textWidth, textHeads, textLayers, melCount, ftype: Int32

        init(_ reader: inout Reader) throws(ModelFileError) {
            vocabularySize = try reader.int32()
            audioContext = try reader.int32()
            audioWidth = try reader.int32()
            audioHeads = try reader.int32()
            audioLayers = try reader.int32()
            textContext = try reader.int32()
            textWidth = try reader.int32()
            textHeads = try reader.int32()
            textLayers = try reader.int32()
            melCount = try reader.int32()
            ftype = try reader.int32()
        }

        /// The bounds of the OpenAI models. Each bound keeps the largest tensor, the token embedding,
        /// under 2^31 elements and bytes (Invariant T of `Sources/CWhisper/README.dirigible`).
        func check() throws(ModelFileError) {
            guard WhisperModelFile.vocabularySizes.contains(vocabularySize) else {
                throw .unsupported("n_vocab \(vocabularySize)")
            }
            guard audioWidth == textWidth else {
                throw .unsupported("n_audio_state \(audioWidth) and n_text_state \(textWidth)")
            }
            guard WhisperModelFile.headsOfWidth[textWidth] == textHeads else {
                throw .unsupported("n_text_state \(textWidth) with n_text_head \(textHeads)")
            }
            guard WhisperModelFile.headsOfWidth[audioWidth] == audioHeads else {
                throw .unsupported("n_audio_state \(audioWidth) with n_audio_head \(audioHeads)")
            }
            guard WhisperModelFile.layerCounts.contains(audioLayers) else {
                throw .unsupported("n_audio_layer \(audioLayers)")
            }
            guard WhisperModelFile.layerCounts.contains(textLayers) else {
                throw .unsupported("n_text_layer \(textLayers)")
            }
            guard WhisperModelFile.melCounts.contains(melCount) else { throw .unsupported("n_mels \(melCount)") }
            guard audioContext == WhisperModelFile.audioContext else {
                throw .unsupported("n_audio_ctx \(audioContext)")
            }
            guard textContext == WhisperModelFile.textContext else { throw .unsupported("n_text_ctx \(textContext)") }
            guard ftype >= 0, WhisperModelFile.ftypes.contains(ftype % 1_000) else {
                throw .unsupported("ftype \(ftype)")
            }
        }
    }

    /// Reads a file with `pread` in chunks of 1 MiB, never with a map: a map of a file that another
    /// process cuts ends the reading process with SIGBUS.
    struct Reader {
        let size: Int
        private(set) var offset = 0
        private var buffer: [UInt8] = []
        private var bufferStart = 0
        /// A `pread` of the file into the buffer at the offset: the byte count, or -1 with errno.
        private let pread: (UnsafeMutableRawBufferPointer, off_t) -> Int

        init(size: Int, pread: @escaping (UnsafeMutableRawBufferPointer, off_t) -> Int) {
            self.size = size
            self.pread = pread
        }

        init(descriptor: Int32, size: Int) {
            self.init(size: size) { Darwin.pread(descriptor, $0.baseAddress, $0.count, $1) }
        }

        mutating func take(_ count: Int) throws(ModelFileError) -> ArraySlice<UInt8> {
            guard count >= 0, count <= size - offset else { throw .truncated }
            if offset < bufferStart || offset + count > bufferStart + buffer.count { try fill(count) }
            let start = offset - bufferStart
            offset += count
            return buffer[start..<start + count]
        }

        mutating func skip(_ count: Int) throws(ModelFileError) {
            guard count >= 0, count <= size - offset else { throw .truncated }
            offset += count
        }

        mutating func int32() throws(ModelFileError) -> Int32 {
            Int32(littleEndian: try take(4).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        }

        /// Reads until `length` bytes or the end of the file: a `pread` can give fewer bytes than
        /// asked, and EINTR asks for the read again.
        private mutating func fill(_ count: Int) throws(ModelFileError) {
            let length = min(max(count, 1 << 20), size - offset)
            var chunk = [UInt8](repeating: 0, count: length)
            var filled = 0
            while filled < length {
                let read = chunk.withUnsafeMutableBytes {
                    pread(UnsafeMutableRawBufferPointer(rebasing: $0[filled...]), off_t(offset + filled))
                }
                if read < 0 {
                    if errno == EINTR { continue }
                    throw .unreadable(errno: errno)
                }
                if read == 0 { throw .truncated }
                filled += read
            }
            buffer = chunk
            bufferStart = offset
        }
    }
}
