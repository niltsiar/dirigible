import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The clip shape of an import in one call: a range of the made WAV,
/// the fades, and the level of that range.
extension ImportTests {
    /// The error of an import that throws, or nil.
    private func importError(_ source: URL, _ target: ImportTarget, _ package: ImportPackage) -> ImportError? {
        do throws(ImportError) {
            _ = try importAudio(source, to: target, of: package.session, in: package.url, level: false)
            return nil
        } catch {
            return error
        }
    }

    /// `offset` and `length` are frames of the made WAV at the session rate. A length past its
    /// end stops there; an offset at its end refuses and leaves no file.
    @Test func anImportTakesARangeOfTheMadeFile() throws {
        let package = try ImportPackage(tracks: [("t1", .stereo)])
        let source = package.source("Source.wav")
        try writeSource(
            source, .wav16, rate: 44_100, channels: [ramp(frames: 44_100), ramp(frames: 44_100, channel: 1)])
        let whole = try importAudio(
            source, to: ImportTarget(track: "t1", start: 0), of: package.session, in: package.url, level: false)
        let frames = try ImportedWAV(package.clip("Source.wav")).frames
        package.session = whole.session

        let fitted = try importAudio(
            source, to: ImportTarget(track: "t1", start: 96_000, offset: 4_800, length: Frames(frames - 4_800)),
            of: package.session, in: package.url, level: false)
        let clamped = try importAudio(
            source, to: ImportTarget(track: "t1", start: 192_000, offset: 4_800, length: Frames(frames - 4_799)),
            of: fitted.session, in: package.url, level: false)

        let range = { (clip: ClipID) in clamped.session.clip(clip).map { [$0.clip.offset, $0.clip.length] } }
        #expect(range(fitted.clip) == [4_800, Frames(frames - 4_800)], "offset 4800 and the rest of the WAV")
        #expect(range(clamped.clip) == [4_800, Frames(frames - 4_800)], "a length past the end stops at the end")
        package.session = clamped.session
        let names = package.clipsNames
        let atEnd = importError(source, ImportTarget(track: "t1", start: 288_000, offset: Frames(frames)), package)
        guard case .session(.clipOutsideFile)? = atEnd else {
            Issue.record("an offset at the end: \(String(describing: atEnd))")
            return
        }
        #expect(package.clipsNames == names, "a refused range leaves no file: \(package.clipsNames)")
        for offset in [Frames(-1), Frames.limit + 1, Frames(Int.min)] {
            let error = importError(source, ImportTarget(track: "t1", start: 0, offset: offset), package)
            #expect(error == .session(.frameOutOfRange), "offset \(offset)")
        }
        #expect(package.clipsNames == names, "an offset out of range leaves no file: \(package.clipsNames)")
    }

    /// The import sets the fades of its clip; fades over the clip length refuse with no file.
    @Test func anImportSetsTheFadesOfItsClip() throws {
        let package = try ImportPackage(tracks: [("t1", .mono)])
        let source = package.source("Sting.wav")
        try writeSource(source, .wav16, rate: 48_000, channels: [ramp(frames: 4_800)])
        let fades = try #require(Fades(fadeIn: 480, fadeOut: 960))

        let faded = try importAudio(
            source, to: ImportTarget(track: "t1", start: 0, fades: fades), of: package.session, in: package.url,
            level: false)

        #expect(faded.session.clip(faded.clip)?.clip.fades == fades, "the fades of the clip")
        package.session = faded.session
        let names = package.clipsNames
        let long = try #require(Fades(fadeIn: 3_000, fadeOut: 3_000))
        let error = importError(source, ImportTarget(track: "t1", start: 9_600, fades: long), package)
        guard case .session(.fadeOutsideClip(_, let length))? = error else {
            Issue.record("fades over the clip: \(String(describing: error))")
            return
        }
        #expect(length == 4_800, "the error names the clip length")
        #expect(package.clipsNames == names, "a refused fade leaves no file: \(package.clipsNames)")
    }

    /// The level measures the clip range, not the whole file. The file is 1 s at -6 dBFS, then
    /// 1 s at -26 dBFS, so the quiet range needs about 20 dB more gain.
    @Test func theLevelOfAnImportMeasuresTheClipRange() throws {
        let package = try ImportPackage(tracks: [("t1", .mono)])
        let source = package.source("Two.wav")
        try writeSource(
            source, .wav24, rate: 48_000, channels: tone([(1, -6), (1, -26)], rate: 48_000, layout: .mono))

        let whole = try importAudio(
            source, to: ImportTarget(track: "t1", start: 0), of: package.session, in: package.url)
        let quiet = try importAudio(
            source, to: ImportTarget(track: "t1", start: 192_000, offset: 48_000), of: whole.session,
            in: package.url)

        let gains = [whole.clip, quiet.clip].compactMap { quiet.session.clip($0)?.clip.gain.dB }
        #expect(gains.count == 2 && gains[1] - gains[0] >= 15, "the quiet range gets 15 dB or more: \(gains)")
    }
}
