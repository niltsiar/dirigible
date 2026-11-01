import Foundation

@testable import DirigibleAudio

/// A synthetic ggml whisper model file: the hparams, a mel filter block, a vocabulary, and each
/// tensor of the `create_tensor` calls of `whisper_model_load` (`whisper.cpp:1778-1863`, names of
/// `ASR_TENSOR_NAMES` in `src/whisper-arch.h`) with zero data. The defaults are a tiny-sized model
/// with 1 layer each side and ftype Q8_0.
struct GgmlFixture {
    struct Tensor {
        var name: String
        var type: Int32
        var dimensions: [Int32]
    }

    /// The byte offsets of the parts of a written file.
    struct Layout {
        var melFilters = 0
        var vocabulary = 0
        var firstTensor = 0
        var headers: [String: Int] = [:]
        var data: [String: Int] = [:]
        var end = 0
    }

    var vocabularySize: Int32 = 51_865
    var audioContext: Int32 = 1_500
    var audioWidth: Int32 = 384
    var audioHeads: Int32 = 6
    var audioLayers: Int32 = 1
    var textContext: Int32 = 448
    var textWidth: Int32 = 384
    var textHeads: Int32 = 6
    var textLayers: Int32 = 1
    var melCount: Int32 = 80
    /// GGML_FTYPE_MOSTLY_Q8_0; its weight tensors have the type id 8.
    var ftype: Int32 = 7
    var fftBins: Int32 = 201
    /// The tokens 0 to 255, one byte each, so the token " " is in the list.
    var tokens: [[UInt8]] = (0...255).map { [UInt8($0)] }
    /// Nil writes `tokens.count`.
    var vocabularyCount: Int32?
    /// Nil writes the tensors of the hparams.
    var tensors: [Tensor]?

    /// Bytes and values per block of the type ids that the fixture writes.
    static let blocks: [Int32: (bytes: Int, values: Int)] = [
        0: (4, 1), 1: (2, 1), 8: (34, 32), 12: (144, 256),
    ]

    /// The tensors of `whisper_model_load` for the hparams: weights in the type of the ftype, the
    /// conv weights in F16 (F32 for ftype 0), the rest in F32.
    var modelTensors: [Tensor] {
        let weight: Int32 = [0: 0, 1: 1, 7: 8][ftype % 1_000] ?? 8
        let conv: Int32 = weight == 0 ? 0 : 1
        let width = audioWidth
        let text = textWidth
        func block(_ prefix: String, _ w: Int32) -> [Tensor] {
            [
                Tensor(name: prefix + "mlp_ln.weight", type: 0, dimensions: [w]),
                Tensor(name: prefix + "mlp_ln.bias", type: 0, dimensions: [w]),
                Tensor(name: prefix + "mlp.0.weight", type: weight, dimensions: [w, 4 * w]),
                Tensor(name: prefix + "mlp.0.bias", type: 0, dimensions: [4 * w]),
                Tensor(name: prefix + "mlp.2.weight", type: weight, dimensions: [4 * w, w]),
                Tensor(name: prefix + "mlp.2.bias", type: 0, dimensions: [w]),
            ] + attention(prefix + "attn", w)
        }
        func attention(_ prefix: String, _ w: Int32) -> [Tensor] {
            [
                Tensor(name: prefix + "_ln.weight", type: 0, dimensions: [w]),
                Tensor(name: prefix + "_ln.bias", type: 0, dimensions: [w]),
                Tensor(name: prefix + ".query.weight", type: weight, dimensions: [w, w]),
                Tensor(name: prefix + ".query.bias", type: 0, dimensions: [w]),
                Tensor(name: prefix + ".key.weight", type: weight, dimensions: [w, w]),
                Tensor(name: prefix + ".value.weight", type: weight, dimensions: [w, w]),
                Tensor(name: prefix + ".value.bias", type: 0, dimensions: [w]),
                Tensor(name: prefix + ".out.weight", type: weight, dimensions: [w, w]),
                Tensor(name: prefix + ".out.bias", type: 0, dimensions: [w]),
            ]
        }
        var list = [
            Tensor(name: "encoder.positional_embedding", type: 0, dimensions: [width, audioContext]),
            Tensor(name: "encoder.conv1.weight", type: conv, dimensions: [3, melCount, width]),
            Tensor(name: "encoder.conv1.bias", type: 0, dimensions: [1, width]),
            Tensor(name: "encoder.conv2.weight", type: conv, dimensions: [3, width, width]),
            Tensor(name: "encoder.conv2.bias", type: 0, dimensions: [1, width]),
            Tensor(name: "encoder.ln_post.weight", type: 0, dimensions: [width]),
            Tensor(name: "encoder.ln_post.bias", type: 0, dimensions: [width]),
        ]
        for n in 0..<max(audioLayers, 0) { list += block("encoder.blocks.\(n).", width) }
        list += [
            Tensor(name: "decoder.positional_embedding", type: 0, dimensions: [text, textContext]),
            Tensor(name: "decoder.token_embedding.weight", type: weight, dimensions: [text, vocabularySize]),
            Tensor(name: "decoder.ln.weight", type: 0, dimensions: [text]),
            Tensor(name: "decoder.ln.bias", type: 0, dimensions: [text]),
        ]
        for n in 0..<max(textLayers, 0) {
            list += block("decoder.blocks.\(n).", text) + attention("decoder.blocks.\(n).cross_attn", text)
        }
        return list
    }

    /// The file bytes and the offsets of their parts. A tensor of a type id that `blocks` does not
    /// list, or with a dimension under 1, has no data bytes.
    func bytes() -> (data: Data, layout: Layout) {
        var data = Data()
        var layout = Layout()
        func put(_ values: Int32...) {
            for value in values { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        }
        put(Int32(bitPattern: 0x6767_6d6c))
        put(vocabularySize, audioContext, audioWidth, audioHeads, audioLayers, textContext, textWidth, textHeads)
        put(textLayers, melCount, ftype)
        layout.melFilters = data.count
        put(melCount, fftBins)
        data.append(Data(count: Int(max(melCount, 0)) * Int(max(fftBins, 0)) * 4))
        layout.vocabulary = data.count
        put(vocabularyCount ?? Int32(tokens.count))
        for token in tokens {
            put(Int32(token.count))
            data.append(contentsOf: token)
        }
        layout.firstTensor = data.count
        for tensor in tensors ?? modelTensors {
            layout.headers[tensor.name] = data.count
            let name = Array(tensor.name.utf8)
            put(Int32(tensor.dimensions.count), Int32(name.count), tensor.type)
            for dimension in tensor.dimensions { put(dimension) }
            data.append(contentsOf: name)
            layout.data[tensor.name] = data.count
            let elements = tensor.dimensions.reduce(1) { $0 * Int(max($1, 0)) }
            if let block = Self.blocks[tensor.type] { data.append(Data(count: elements / block.values * block.bytes)) }
        }
        layout.end = data.count
        return (data, layout)
    }

    /// Writes the file to `folder`, after `edit` changes its bytes, and gives its URL.
    func write(
        in folder: URL, name: String = "ggml-test.bin", edit: (inout Data, Layout) -> Void = { _, _ in }
    ) throws -> URL {
        let (written, layout) = bytes()
        var data = written
        edit(&data, layout)
        let url = folder.appending(path: name)
        try data.write(to: url)
        return url
    }
}

extension GgmlFixture {
    /// The result of `WhisperModelFile.read(_:)` on the written file.
    func read(edit: (inout Data, Layout) -> Void = { _, _ in }) throws -> Result<WhisperModelFile, ModelFileError> {
        let folder = try TemporaryFolder()
        let url = try write(in: folder.url, edit: edit)
        do throws(ModelFileError) { return .success(try WhisperModelFile.read(url)) } catch { return .failure(error) }
    }
}

extension Data {
    /// Writes `value` little-endian at `offset`.
    mutating func put<T: FixedWidthInteger>(_ value: T, at offset: Int) {
        Swift.withUnsafeBytes(of: value.littleEndian) { replaceSubrange(offset..<offset + $0.count, with: $0) }
    }

    mutating func put(_ value: Float, at offset: Int) { put(value.bitPattern, at: offset) }
}
