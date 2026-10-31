import Foundation
import Testing

@testable import DirigibleAudio

struct WhisperModelTests {
    /// C27: the count and the SHA-256 (LFS oid) of the file at the pinned revision 5359861c.
    @Test func theTurboEntryHasTheCountAndTheHashOfThePinnedRevision() throws {
        let turbo = try #require(WhisperModel(rawValue: "large-v3-turbo-q5_0"))
        #expect(turbo.byteCount == 574_041_195)
        #expect(turbo.sha256 == "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2")
        #expect(
            turbo.url.absoluteString
                == "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-turbo-q5_0.bin"
        )
    }

    @Test func aFileOfTheWrongSizeGivesNoCheckedModel() throws {
        let folder = try TemporaryFolder()
        try Data(count: 1_000).write(to: folder.url.appending(path: WhisperModel.tinyQ51.fileName))
        #expect(WhisperModel.tinyQ51.checked(in: folder.url) == nil)
        #expect(WhisperModel.base.checked(in: folder.url) == nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func aModelFileWithOneChangedByteGivesNoCheckedModel() throws {
        let fixture = try WhisperFixture.model(.tinyQ51)
        let folder = try TemporaryFolder()
        let copy = folder.url.appending(path: WhisperModel.tinyQ51.fileName)
        var bytes = try Data(contentsOf: fixture.url)
        #expect(WhisperModel.tinyQ51.checked(at: fixture.url) == fixture)
        bytes[bytes.count / 2] ^= 0x01
        try bytes.write(to: copy)
        #expect(WhisperModel.tinyQ51.checked(at: copy) == nil)
    }
}
