import CryptoKit
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// A later build opens an older archive (decision 0072, run criterion C3; decision 0024 P2).
///
/// Fixture: `Fixtures/archived-v22.dirigible`, which `dirigible file archive` of the build of
/// session version 22 wrote: the 24-bit tones `host.wav` (mono) and `music.wav` (stereo), 24,000
/// frames each at 48 kHz, as FLAC files of the Apple encoder. Keep the fixture and this test for
/// each later version.
struct ArchiveFixtureTests {
    /// The SHA-256 of the `data` chunk of each clip WAV before the archive.
    static let data = [
        "host.wav": "324adb5a17971940eb658a8ff7a5bae21c401e7f47399d50b80061300cad8c65",
        "music.wav": "39ecd6e10404c75cee4688444f42000534976b9f02844bf430e82f76d36d099b",
    ]

    @Test func anArchivedFixtureOpensAndUnarchives() async throws {
        let package = try TemporaryPackage()
        let fixture = URL(filePath: #filePath).deletingLastPathComponent()
            .appending(path: "Fixtures/archived-v22.dirigible")
        try FileManager.default.copyItem(at: fixture, to: package.url)
        #expect(String(decoding: try package.xml(), as: UTF8.self).contains(#"version="22" sampleRate="48000""#))
        let session = try package.read()
        #expect(session.archive == .flac)
        #expect(try checkMedia(session, package: package.url).isEmpty, "the media check reads each FLAC")

        let result = try await package.run("file", "unarchive", "PKG")

        #expect(result.status == 0, "\(result)")
        let clips = package.url.appending(path: clipsFolderName)
        #expect(try FileManager.default.contentsOfDirectory(atPath: clips.path).sorted() == ["host.wav", "music.wav"])
        for (name, hash) in Self.data {
            let digest = SHA256.hash(data: try dataChunk(of: clips.appending(path: name)))
            #expect(digest.map { String(format: "%02x", $0) }.joined() == hash, "the data of \(name)")
        }
        #expect(try package.read().archive == nil)
    }

    /// The bytes of the `data` chunk of a RIFF WAV.
    private func dataChunk(of url: URL) throws -> Data {
        let bytes = try Data(contentsOf: url)
        var offset = 12
        while offset + 8 <= bytes.count {
            let size = Int(bytes[offset + 4..<offset + 8].reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            if bytes[offset..<offset + 4] == Data("data".utf8) { return bytes[offset + 8..<offset + 8 + size] }
            offset += 8 + size + size % 2
        }
        throw CocoaError(.fileReadCorruptFile)
    }
}
