import AVFoundation
import DirigibleAudio
import DirigibleCore
import Foundation
import Testing

/// `dirigible peaks` (timeline-view criterion 8, decisions 0011 and 0017): the cache state of
/// each pool file after a Studio pass. The cache folder is next to the package.
@Suite(.serialized)
struct PeaksCommandTests {
    let package: TemporaryPackage
    var cache: String { package.folder.appending(path: "Peaks").path }

    /// Track `t1` with clip `c1` of `f1.wav` (10 s mono), and pool file `gone.wav`, which is not
    /// on the disk.
    init() throws {
        package = try Self.package()
        try package.edit { session in
            try session.addFile(AudioFile(id: "gone", path: "gone.wav", layout: .mono, length: 480_000))
        }
    }

    static func package() throws -> TemporaryPackage {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "f1", path: "f1.wav", layout: .mono, length: 480_000))
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.place(Clip(id: "c1", file: "f1", start: 0, offset: 0, length: 480_000), on: "t1")
        let package = try TemporaryPackage(session)
        try writeWAV(package.url.appending(path: "Clips/f1.wav"), level: 0.25)
        return package
    }

    /// 480,000 frames of `level` DC as a 32-bit float WAV.
    static func writeWAV(_ url: URL, level: Float) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480_000))
        buffer.frameLength = 480_000
        buffer.floatChannelData![0].update(repeating: level, count: 480_000)
        try file.write(from: buffer)
    }

    /// Opens a Studio with the cache folder and waits until the peaks of `f1` are ready. The
    /// Studio stays open when `keep` is true.
    @MainActor
    static func pass(_ url: URL, cache: String, keep: Bool = false) async throws -> Studio? {
        let studio = try await Studio.open(url, peakCache: URL(filePath: cache))
        let end = ContinuousClock.now + .seconds(30)
        while !(studio.peaks["f1"].map { if case .ready = $0 { true } else { false } } ?? false) {
            guard ContinuousClock.now < end else {
                Issue.record("the peaks of f1 are not ready in 30 s")
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        await studio.settle()
        return keep ? studio : nil
    }

    @Test func hitMissAndMissing() async throws {
        #expect(
            try package.run("peaks", "PKG", "--cache", cache)
                == CLIResult(
                    status: 0, stdout: "f1.wav\tmiss\ngone.wav\tmissing\n", stderr: ""), "an empty cache folder")

        _ = try await Self.pass(package.url, cache: cache)
        #expect(
            try package.run("peaks", "PKG", "--cache", cache)
                == CLIResult(
                    status: 0, stdout: "f1.wav\thit 1875\ngone.wav\tmissing\n", stderr: ""))

        try Self.writeWAV(package.url.appending(path: "Clips/f1.wav"), level: 0.5)
        #expect(
            try package.run("peaks", "PKG", "--cache", cache)
                == CLIResult(
                    status: 0, stdout: "f1.wav\tmiss\ngone.wav\tmissing\n", stderr: ""), "a rewrite")
    }

    /// The pool path is the same in both packages; the stamp tells their WAVs apart.
    @Test func twoPackagesInOneCacheFolder() async throws {
        let other = try Self.package()
        _ = try await Self.pass(package.url, cache: cache)

        #expect(try other.run("peaks", "PKG", "--cache", cache).stdout == "f1.wav\tmiss\n")
        #expect(try package.run("peaks", "PKG", "--cache", cache).stdout.hasPrefix("f1.wav\thit 1875\n"))
    }

    @Test func itWritesNothing() async throws {
        _ = try await Self.pass(package.url, cache: cache)
        func snapshot() throws -> [String: Data] {
            var files: [String: Data] = [:]
            for root in [package.url.path, cache] {
                for path in try FileManager.default.subpathsOfDirectory(atPath: root) {
                    var folder: ObjCBool = false
                    let full = root + "/" + path
                    if FileManager.default.fileExists(atPath: full, isDirectory: &folder), !folder.boolValue {
                        files[full] = try Data(contentsOf: URL(filePath: full))
                    }
                }
            }
            return files
        }
        let before = try snapshot()

        #expect(try package.run("peaks", "PKG", "--cache", cache).status == 0)

        #expect(try snapshot() == before)
    }

    @Test func itRunsWhileAStudioHoldsTheLock() async throws {
        let studio = try await Self.pass(package.url, cache: cache, keep: true)

        #expect(try package.run("peaks", "PKG", "--cache", cache).stdout == "f1.wav\thit 1875\ngone.wav\tmissing\n")
        _ = studio
    }
}
