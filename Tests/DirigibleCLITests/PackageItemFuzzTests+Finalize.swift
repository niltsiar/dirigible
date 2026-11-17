import AVFoundation
import Foundation
import Testing

@testable import DirigibleAudio
@testable import DirigibleCore

/// The recovery of a take after a `take finalize` that exits 2 with the take placed.
extension PackageItemFuzzTests {
    /// The samples of the first channel of the audio file at `url`, up to 2^20 frames. A buffer of
    /// `file.length` frames reads fewer samples than the capture CAF of `pendingTake()` holds.
    static func samples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1 << 20))
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    /// A second `take finalize` with the mode of `Clips/` back at 0755: it finalizes the take with
    /// one clip and one file in `Clips/`, whose samples equal those of the capture.
    static func secondFinalizeProblems(_ package: URL) async throws -> [String] {
        let capture = try samples(
            package.appending(path: "Capture/\(SegmentName(take: 1, arm: 1, segment: 1).cafName)"))
        let result = try await dirigible(
            shell: #"exec "$0" "$@""#, arguments: [dirigibleBinary.path, "take", "finalize", package.path],
            limit: .seconds(10))
        let clips = package.appending(path: "Clips")
        let listing = try FileManager.default.contentsOfDirectory(atPath: clips.path).filter { $0 != "victim.wav" }
            .sorted()
        let sizes = try listing.map {
            "\($0) \(try FileManager.default.attributesOfItem(atPath: clips.appending(path: $0).path)[.size] ?? "?")"
        }
        guard result.status == 0 else {
            return ["the second finalize: exit \(result.status), Clips/ \(sizes): \(result.stderr.prefix(300))"]
        }
        let session = try Session(contentsOf: package)
        let paths = session.files.values.map(\.path)
        var problems: [String] = []
        if session.recording != nil { problems.append("the take is pending after the second finalize") }
        if listing != paths || session.tracks.map(\.clips.count) != [1] {
            problems.append("Clips/ \(sizes), session files \(paths), clips \(session.tracks.map(\.clips.count))")
        } else if try samples(clips.appending(path: listing[0])) != capture {
            problems.append("the clip samples are not the capture samples")
        }
        if capture != [Float](repeating: 0.25, count: 96_000) { problems.append("the capture lost samples") }
        return problems
    }
}
