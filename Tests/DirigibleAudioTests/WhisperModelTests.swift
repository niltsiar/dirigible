import Foundation
import Testing

@testable import DirigibleAudio

struct WhisperModelTests {
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
