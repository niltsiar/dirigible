import Foundation
import Testing

@testable import DirigibleAudio

/// C1 to C4 of run user-model-file: the refusals and the passes of the parse of a model
/// file of the user (decision 0065, D8).
struct WhisperModelFileTests {
    @Test func aSyntheticFileWithEachTensorPasses() throws {
        let fixture = GgmlFixture()
        let size = fixture.bytes().layout.end

        let file = try fixture.read().get()

        #expect(file.facts == WhisperModelFacts(audioLayers: 1, textLayers: 1, melCount: 80, isMultilingual: true))
        #expect(file.facts.kind == nil && file.ftype == 7 && file.byteCount == size)
    }

    @Test(arguments: ["empty", "text", "random", "wav"])
    func aFileWithNoGgmlMagicIsNotAWhisperModel(_ kind: String) throws {
        let folder = try TemporaryFolder()
        let url = folder.url.appending(path: "\(kind).bin")
        var random = SeededGenerator(seed: 11)
        let bytes: Data =
            switch kind {
            case "empty": Data()
            case "text": Data(String(repeating: "hello, this is not a model\n", count: 100).utf8)
            case "random": Data((0..<4_096).map { _ in UInt8.random(in: 0...255, using: &random) })
            default: Data("RIFF".utf8) + Data([0x24, 0, 0, 0]) + Data("WAVEfmt ".utf8) + Data(count: 64)
            }
        try bytes.write(to: url)

        #expect(throws: ModelFileError.notWhisperModel) { try WhisperModelFile.read(url) }
    }

    @Test func theBundledSileroFileIsUnsupported() throws {
        let silero = URL(filePath: #filePath).deletingLastPathComponent()
            .appending(path: "../../Support/Resources/ggml-silero-v6.2.0.bin")

        #expect(throws: ModelFileError.unsupported("n_vocab 10")) { try WhisperModelFile.read(silero) }
    }

    @Test func aFtypeOutsideTheQuantizeSetIsUnsupported() throws {
        var bad = GgmlFixture()
        bad.ftype = 99
        var versioned = GgmlFixture()
        versioned.ftype = 1_009

        #expect(try bad.read() == .failure(.unsupported("ftype 99")))
        #expect(try versioned.read().get().ftype == 1_009)
    }

    /// 51,864 is English-only, 51,865 multilingual, 51,866 large-v3. More gives over 100 languages,
    /// and the loader ends the process.
    @Test func theVocabularySizeIsFrom51864To51866() throws {
        var results: [Int32: Result<Bool, ModelFileError>] = [:]
        for size: Int32 in [51_863, 51_864, 51_866, 51_867] {
            var fixture = GgmlFixture()
            fixture.vocabularySize = size
            results[size] = try fixture.read().map(\.facts.isMultilingual)
        }

        #expect(results[51_863] == .failure(.unsupported("n_vocab 51863")))
        #expect(results[51_864] == .success(false))
        #expect(results[51_866] == .success(true))
        #expect(results[51_867] == .failure(.unsupported("n_vocab 51867")))
    }

    @Test func eachHparamOutsideTheModelsIsUnsupported() throws {
        let cases: [(String, (inout GgmlFixture) -> Void)] = [
            ("n_text_state 384 with n_text_head 0", { $0.textHeads = 0 }),
            ("n_text_state 384 with n_text_head 7", { $0.textHeads = 7 }),
            ("n_audio_state 384 with n_audio_head 7", { $0.audioHeads = 7 }),
            ("n_audio_state 512 and n_text_state 384", { $0.audioWidth = 512 }),
            ("n_mels 81", { $0.melCount = 81 }),
            ("n_audio_ctx 1501", { $0.audioContext = 1_501 }),
            ("n_text_ctx 449", { $0.textContext = 449 }),
            ("n_fft 200", { $0.fftBins = 200 }),
            ("n_audio_layer 0", { $0.audioLayers = 0 }),
            ("n_text_layer 0", { $0.textLayers = 0 }),
            ("n_audio_layer 33", { $0.audioLayers = 33 }),
            ("n_text_layer 33", { $0.textLayers = 33 }),
        ]
        for (reason, change) in cases {
            var fixture = GgmlFixture()
            change(&fixture)
            #expect(try fixture.read() == .failure(.unsupported(reason)), "\(reason)")
        }
    }

    @Test func oneAndThirtyTwoLayersPass() throws {
        var audio = GgmlFixture()
        audio.audioLayers = 32
        var text = GgmlFixture()
        text.textLayers = 32

        let large = try audio.read().get().facts
        #expect(large.audioLayers == 32 && large.textLayers == 1 && large.kind == .large)
        #expect(try text.read().get().facts.textLayers == 32)
    }

    @Test func aVocabularyCountOfMinusOneIsDamaged() throws {
        var fixture = GgmlFixture()
        fixture.vocabularyCount = -1

        #expect(try fixture.read() == .failure(.damaged("vocabulary count -1")))
    }

    @Test func aVocabularyCountOfZeroOrOverNVocabIsDamaged() throws {
        var empty = GgmlFixture()
        empty.tokens = []
        var over = GgmlFixture()
        over.vocabularyCount = 51_866

        #expect(try empty.read() == .failure(.damaged("vocabulary count 0")))
        #expect(try over.read() == .failure(.damaged("vocabulary count 51866")))
    }

    /// The catalog files have 50,257 tokens.
    @Test func theVocabularyCountOfTheCatalogFilesPasses() throws {
        var fixture = GgmlFixture()
        fixture.tokens += (256..<50_257).map { (n: Int) -> [UInt8] in
            let letter = { (value: Int) -> UInt8 in UInt8(value % 26) + 0x61 }
            return [letter(n), letter(n / 26)]
        }

        #expect(fixture.tokens.count == 50_257)
        #expect(throws: Never.self) { try fixture.read().get() }
    }

    /// `whisper_full` reads the id of the token " " with `at`, which throws with no catch.
    @Test func aVocabularyWithNoOneByteSpaceTokenIsDamaged() throws {
        var fixture = GgmlFixture()
        fixture.tokens[0x20] = [0x01]
        var spaceInLongerToken = fixture
        spaceInLongerToken.tokens[0x21] = [0x20, 0x20]

        #expect(try fixture.read() == .failure(.damaged("no token \" \"")))
        #expect(try spaceInLongerToken.read() == .failure(.damaged("no token \" \"")))
        #expect(throws: Never.self) { try GgmlFixture().read().get() }
    }

    /// C3: the catalog files of `scripts/fetch-whisper-test-model.sh` pass with their facts.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func eachCatalogFilePasses() throws {
        let expected: [WhisperModel: WhisperModelFacts] = [
            .tinyQ51: WhisperModelFacts(audioLayers: 4, textLayers: 4, melCount: 80, isMultilingual: true),
            .base: WhisperModelFacts(audioLayers: 6, textLayers: 6, melCount: 80, isMultilingual: true),
            .smallQ51: WhisperModelFacts(audioLayers: 12, textLayers: 12, melCount: 80, isMultilingual: true),
        ]
        for (model, facts) in expected {
            let url = try WhisperFixture.model(model).url
            let file = try WhisperModelFile.read(url)
            #expect(file.facts == facts && file.byteCount == model.byteCount, "\(model)")
        }
    }

    /// C4: the token embedding of the largest bounds is the largest tensor, and it stays under 2^31
    /// elements and bytes in F32 (Invariant T of `Sources/CWhisper/README.dirigible`).
    @Test func theLargestTensorOfTheBoundsIsUnderTheLimit() throws {
        let width = try #require(WhisperModelFile.headsOfWidth.keys.max()).asInt
        let vocabulary = WhisperModelFile.vocabularySizes.upperBound.asInt
        let mels = try #require(WhisperModelFile.melCounts.max()).asInt
        let tokenEmbedding = width * vocabulary
        let others = [
            4 * width * width, 3 * width * width, width * WhisperModelFile.audioContext.asInt,
            width * WhisperModelFile.textContext.asInt,
            3 * width * mels,
        ]

        #expect(tokenEmbedding == 66_388_480 && tokenEmbedding * 4 == 265_553_920)
        #expect(tokenEmbedding * 4 < 1 << 31)
        #expect(others.allSatisfy { $0 < tokenEmbedding })
    }
}

/// C2: the walk of the tensor headers and the scan of the decoder positional embedding.
extension WhisperModelFileTests {
    static let positional = "decoder.positional_embedding"
    /// A tensor that the parse does not name.
    static let other = "encoder.ln_post.bias"

    /// The loader takes a file that ends after the vocabulary as an empty model, and `whisper_full`
    /// then throws `std::out_of_range`.
    @Test func aFileWithNoTensorIsTruncated() throws {
        #expect(
            try GgmlFixture().read { data, layout in data = data.prefix(layout.firstTensor) } == .failure(.truncated))
    }

    /// The loader takes a file with its last byte missing, so only the parse refuses it.
    @Test func aFileOneByteShortIsTruncated() throws {
        #expect(try GgmlFixture().read { data, layout in data = data.prefix(layout.end - 1) } == .failure(.truncated))
    }

    @Test func aCutInsideEachPartIsTruncated() throws {
        let cuts: [(String, (GgmlFixture.Layout) -> Int)] = [
            ("hparams", { _ in 20 }),
            ("mel filters", { $0.melFilters + 100 }),
            ("vocabulary", { $0.vocabulary + 10 }),
            ("tensor header", { $0.headers[Self.other, default: 0] + 14 }),
            ("tensor data", { $0.data[Self.positional, default: 0] + 8 }),
        ]
        for (part, offset) in cuts {
            let result = try GgmlFixture().read { data, layout in data = data.prefix(offset(layout)) }
            #expect(result == .failure(.truncated), "\(part)")
        }
        #expect(throws: Never.self) { try GgmlFixture().read().get() }
    }

    /// Seeded: each cut of the file at a random offset is refused, never passed.
    @Test func eachCutOfTheFileIsRefused() throws {
        var random = SeededGenerator(seed: 23)
        let end = GgmlFixture().bytes().layout.end
        for _ in 0..<12 {
            let cut = Int.random(in: 0..<end, using: &random)
            let result = try GgmlFixture().read { data, _ in data = data.prefix(cut) }
            #expect(throws: (any Error).self, "cut at \(cut)") { try result.get() }
        }
    }

    @Test func oneByteAfterTheLastTensorIsDamaged() throws {
        let result = try GgmlFixture().read { data, _ in data.append(0) }

        #expect(result == .failure(.damaged("bytes after the last tensor: 1")))
    }

    @Test func eachBadTensorHeaderIsDamaged() throws {
        let other = Self.other
        let cases: [(String, (inout GgmlFixture.Tensor) -> Void)] = [
            ("tensor type 99 of \(other)", { $0.type = 99 }),
            ("dimension count 0", { $0.dimensions = [] }),
            ("dimension count 5", { $0.dimensions = [384, 1, 1, 1, 1] }),
            ("dimensions [384, 0] of \(other)", { $0.dimensions = [384, 0] }),
            ("dimensions [-1] of \(other)", { $0.dimensions = [-1] }),
            ("name length 0", { $0.name = "" }),
            ("name length 65", { $0.name = String(repeating: "n", count: 65) }),
            ("row of 384 values of type 12 in \(other)", { $0.type = 12 }),
        ]
        for (reason, change) in cases {
            var fixture = GgmlFixture()
            fixture.tensors = fixture.modelTensors.map { tensor in
                var tensor = tensor
                if tensor.name == other { change(&tensor) }
                return tensor
            }
            #expect(try fixture.read() == .failure(.damaged(reason)), "\(reason)")
        }
    }

    /// The loader counts loads, not names: a tensor given twice in place of a missing one loads and
    /// leaves the missing tensor with no data.
    @Test func aTensorNameGivenTwiceIsDamaged() throws {
        var fixture = GgmlFixture()
        fixture.tensors = fixture.modelTensors.map { tensor in
            var tensor = tensor
            if tensor.name == "encoder.ln_post.weight" { tensor.name = Self.other }
            return tensor
        }

        #expect(try fixture.read() == .failure(.damaged("tensor \(Self.other) twice")))
    }

    /// The near case of the header cases: the loader refuses an unknown name with a null context,
    /// so the parse holds no name table. A name of 64 bytes is the longest that passes.
    @Test func aRenamedTensorPasses() throws {
        var fixture = GgmlFixture()
        fixture.tensors = fixture.modelTensors.map { tensor in
            var tensor = tensor
            if tensor.name == Self.other { tensor.name = String(repeating: "n", count: 64) }
            return tensor
        }

        #expect(throws: Never.self) { try fixture.read().get() }
    }

    /// A 1 s trial does not reach the last rows: they end only a longer job.
    @Test func aNaNInTheLastPositionalRowIsDamaged() throws {
        let fixture = GgmlFixture()
        let result = try fixture.read { data, layout in
            let lastRow = layout.data[Self.positional, default: 0] + 447 * 384 * 4
            data.put(Float.nan, at: lastRow + 383 * 4)
        }

        #expect(result == .failure(.damaged("NaN or infinite value in \(Self.positional)")))
    }

    @Test func anInfinityInTheFirstPositionalRowIsDamaged() throws {
        let result = try GgmlFixture().read { data, layout in
            data.put(Float.infinity, at: layout.data[Self.positional, default: 0])
        }

        #expect(result == .failure(.damaged("NaN or infinite value in \(Self.positional)")))
    }

    @Test func aFileWithNoPositionalTensorIsDamaged() throws {
        var fixture = GgmlFixture()
        fixture.tensors = fixture.modelTensors.map { tensor in
            var tensor = tensor
            if tensor.name == Self.positional { tensor.name = "decoder.positional_embedding.moved" }
            return tensor
        }

        #expect(try fixture.read() == .failure(.damaged("no \(Self.positional)")))
    }

    /// The loader makes the decoder positional embedding F32 with the dims (n_text_state, n_text_ctx).
    @Test func aPositionalTensorOfAnotherTypeIsDamaged() throws {
        var fixture = GgmlFixture()
        fixture.tensors = fixture.modelTensors.map { tensor in
            var tensor = tensor
            if tensor.name == Self.positional { tensor.type = 1 }
            return tensor
        }

        let reason = "\(Self.positional) of type 1 and dimensions [384, 448]"
        #expect(try fixture.read() == .failure(.damaged(reason)))
    }

    /// A read that EINTR ends and reads that give fewer bytes than asked give the bytes of the
    /// file: the reader reads again.
    @Test func shortReadsAndEINTRGiveTheBytesOfTheFile() throws {
        let bytes = (0..<10_000).map { UInt8(truncatingIfNeeded: $0 &* 7) }
        var calls = 0
        var reader = WhisperModelFile.Reader(size: bytes.count) { buffer, offset in
            calls += 1
            guard calls > 1 else {
                errno = EINTR
                return -1
            }
            let count = min(buffer.count, 3, bytes.count - Int(offset))
            buffer.copyBytes(from: bytes[Int(offset)..<Int(offset) + count])
            return count
        }

        #expect(Array(try reader.take(bytes.count)) == bytes)
    }
}

extension Int32 {
    fileprivate var asInt: Int { Int(self) }
}
