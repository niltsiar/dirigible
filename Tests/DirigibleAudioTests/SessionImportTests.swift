import AVFoundation
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The session import (decision 0075). Each source and target is a `MixPackage` with a `.lock`
/// file; `save` writes its `session.xml` with the real writer.
struct SessionImportTests {
    let target: MixPackage

    init() throws {
        target = try SessionImportTests.package("Host")
    }

    static func package(_ name: String, rate: Int = 48_000) throws -> MixPackage {
        let package = try MixPackage(sampleRate: rate, name: name)
        FileManager.default.createFile(atPath: package.url.appending(path: ".lock").path, contents: nil)
        return package
    }

    func run(
        _ source: URL, into target: MixPackage? = nil, at: Int = 0, markers: Bool = false, free: Int64 = .max,
        progress: @escaping (Double) -> Void = { _ in }, isCancelled: @escaping () -> Bool = { false },
        isDownloaded: (URL) -> Bool = { _ in true }
    ) throws(SessionImportError) -> SessionImported {
        let target = target ?? self.target
        return try importSession(
            from: source, into: target.session, in: target.url, identity: PackageID(lockFileOf: target.url), at: at,
            markers: markers, freeBytes: { free }, progress: progress, isCancelled: isCancelled,
            isDownloaded: isDownloaded)
    }

    func clips(_ session: Session, _ track: TrackID) -> [Clip] { session.track(track).map { Array($0.clips) } ?? [] }

    /// The clips of new track `index` of `result`; none when it has no such track.
    func clips(_ result: SessionImported, _ index: Int) -> [Clip] {
        index < result.tracks.count ? clips(result.session, result.tracks[index]) : []
    }

    func names(_ package: MixPackage) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: package.url.appending(path: clipsFolderName).path).sorted()
    }

    /// A call-preset package (`Session.addCallTracks`) with one clip on each track.
    static func callPackage(_ name: String) throws -> MixPackage {
        let package = try package(name)
        try package.addFile("f1", channels: [sine(seconds: 1, rate: 48_000)])
        try package.session.addCallTracks(
            host: "h", guest: "g", names: ("Host", "Guest"), hostDevice: ("mic", 1), guestApp: "us.zoom.xos")
        try package.session.place(Clip(id: "H", file: "f1", start: 0, offset: 0, length: 48_000), on: "h")
        try package.session.place(Clip(id: "G", file: "f1", start: 0, offset: 0, length: 48_000), on: "g")
        try package.session.write(to: package.url)
        return package
    }

    /// C4: a negative offset cuts the source head, here from 44 100 Hz into 48 000 Hz: c = 44 100.
    @Test func importAtANegativeOffsetDropsTheHead() throws {
        let rated = try Self.package("Guest", rate: 44_100)
        try rated.addFile("f1", channels: [sine(seconds: 4, rate: 44_100)])
        try rated.addTrack("t1", clip: "A", file: "f1", start: 0, offset: 0, length: 88_200)
        try rated.session.write(to: rated.url)

        let converted = try run(rated.url, at: -48_000)

        let a = try #require(clips(converted, 0).first)
        #expect(a.start == 0 && a.length == 48_000 && a.offset == 48_000, "the converted rest of the clip")

        let same = try Self.package("Same")
        try same.addFile("f1", channels: [sine(seconds: 4, rate: 48_000)])
        try same.addFile("f2", channels: [sine(seconds: 1, rate: 48_000)])
        try same.addTrack("t1", clip: "A", file: "f1", start: 0, offset: 0, length: 96_000)
        try same.addTrack("t2", clip: "B", file: "f2", start: 0, offset: 0, length: 48_000)
        try same.session.write(to: same.url)

        let later = try run(same.url, at: 48_000)
        #expect(clips(later, 0).map(\.start) == [48_000])

        let cut = try run(same.url, at: -48_000)
        #expect(clips(cut, 0).map { [$0.start, $0.offset, $0.length] } == [[0, 48_000, 48_000]])
        #expect(clips(cut, 1).isEmpty, "a clip that ends at the cut is not imported")
        #expect(cut.session.files.count == target.session.files.count + 1, "its file is not copied")

        let kept = try run(same.url, at: -47_999)
        #expect(clips(kept, 1).map { [$0.start, $0.offset, $0.length] } == [[0, 47_999, 1]])

        #expect(throws: SessionImportError.nothingToImport) { try run(same.url, at: -96_000) }
    }

    /// C1: each source track gives one new last track with its values; solo, route, and presets stay out.
    @Test func importAddsOneTrackForEachSourceTrack() throws {
        let source = try Self.package("Guest")
        try source.addFile("f1", channels: [sine(seconds: 2, rate: 48_000)])
        try source.addFile("f2", channels: [sine(seconds: 1, rate: 48_000)])
        let ride = try #require(GainEnvelope([.init(frame: 100, gain: Gain(dB: -2)!)]))
        try source.session.addTrack("t1", name: "Voice", layout: .mono)
        try source.session.place(
            Clip(id: "A", file: "f1", start: 1_000, offset: 0, length: 48_000, gain: Gain(dB: 1)!, ride: ride), on: "t1"
        )
        try source.session.place(Clip(id: "B", file: "f1", start: 49_000, offset: 48_000, length: 48_000), on: "t1")
        try source.session.setFades(["A": Fades(fadeIn: 480, fadeOut: 0)!])
        try source.session.setCrossfades(["A": 960])
        try source.session.setEnvelope([49_200: Gain(dB: -6)!], clip: "B")
        try source.addTrack("t2", clip: "C", file: "f2", start: 0, offset: 0, length: 48_000)
        try source.session.renameTrack("t2", to: "Music")
        try source.session.addTrack("t3", name: "Extra", layout: .mono)
        try source.session.setGain(Gain(dB: -3)!, track: "t1")
        try source.session.setGain(Gain(dB: 2)!, track: "t3")
        try source.session.setRole(.dialogue, tracks: ["t1"])
        try source.session.setRole(.music, tracks: ["t2"])
        try source.session.setMuted(true, tracks: ["t2"])
        try source.session.setFollowTrack(true, tracks: ["t2"])
        try source.session.setSoloed(true, tracks: ["t3"])
        let match = try VoiceMatch(
            amount: VoiceMatch.Amount(50)!, reference: "Host", curve: Array(repeating: 1, count: 25),
            targetPowers: Array(repeating: 1, count: 25))
        try source.session.setMatch(["t1": match])
        try source.session.setExportPreset(
            ExportPreset(
                name: try PresetName("Feed"),
                options: try PresetOptions(format: .mp3(.k128), layout: .mono, rate: .hz44100, loudness: .podcast)))
        try source.session.write(to: source.url)
        try target.addFile("take1-t1", channels: [[Float](repeating: 0, count: 48_000)])
        try target.addTrack("u1", clip: "Z", file: "take1-t1", start: 0, offset: 0, length: 48_000)
        try target.addTrack("u2", clip: "Y", file: "take1-t1", start: 0, offset: 0, length: 24_000)

        let result = try run(source.url)

        let session = result.session
        #expect(session.tracks.count == 5 && Array(session.tracks.prefix(2)) == target.session.tracks)
        #expect(session.tracks.suffix(3).map(\.id) == result.tracks)
        let new = result.tracks.compactMap { session.track($0) }
        #expect(new.map(\.name) == ["Voice", "Music", "Extra"])
        #expect(new.map(\.gain) == [Gain(dB: -3)!, .zero, Gain(dB: 2)!])
        #expect(new.map(\.role) == [.dialogue, .music, nil])
        #expect(new.map(\.isMuted) == [false, true, false] && new.map(\.isFollowTrack) == [false, true, false])
        #expect(new.map(\.isSoloed) == [false, false, false] && new.allSatisfy { $0.route == nil })
        #expect(new.map(\.match) == [match, nil, nil])
        let expected = Array(source.session.track("t1")!.clips) + Array(source.session.track("t2")!.clips)
        let got = clips(result, 0) + clips(result, 1)
        #expect(
            got.map { [$0.start, $0.offset, $0.length] } == expected.map { [$0.start, $0.offset, $0.length] })
        #expect(got.map(\.gain) == expected.map(\.gain) && got.map(\.fades) == expected.map(\.fades))
        #expect(got.map(\.crossfades) == expected.map(\.crossfades) && got.map(\.envelope) == expected.map(\.envelope))
        #expect(got.map(\.ride) == expected.map(\.ride) && got[0].ride != .empty)
        #expect(session.exportPresets.isEmpty, "the source preset stays out")
        #expect(result.mutedCallTracks == 0)
    }

    /// C1b: two call-preset packages; a clash takes the source session name, and a call track imports muted.
    @Test func twoCallPresetPackagesGiveTheChosenNamesAndMute() throws {
        let host = try Self.callPackage("Host")
        let guest = try Self.callPackage("Guest")

        let result = try run(guest.url, into: host)

        #expect(result.session.tracks.map(\.name) == ["Host", "Guest", "Host (Guest)", "Guest (Guest)"])
        #expect(result.session.tracks.map(\.isMuted) == [false, false, false, true])
        #expect(result.mutedCallTracks == 1)
    }

    /// C1b: the suffix keeps only the scalars that a session stores; no scalar left gives the number form.
    @Test func aSourceNameWithAControlCharacterImports() throws {
        let tabbed = try Self.callPackage("Gu\test")
        try target.session.addTrack("x", name: "Host", layout: .mono)
        let before = try names(target)

        let result = try run(tabbed.url)

        #expect(result.session.tracks.map(\.name) == ["Host", "Host (Guest)", "Guest"])
        #expect(try names(target).count == before.count + 1, "one new file: both clips name f1")

        let near = try Self.package("Near")
        #expect(try run(tabbed.url, into: near).session.tracks.map(\.name) == ["Host", "Guest"])

        let tab = try Self.callPackage("\t")
        #expect(try run(tab.url).session.tracks.map(\.name) == ["Host", "Host (2)", "Guest"])
    }

    /// C1b: a suffix form that is already a name takes the number form, so no name repeats.
    @Test func aSuffixThatStillClashesTakesTheNumberForm() throws {
        let guest = try Self.callPackage("Guest")
        let host = try Self.callPackage("Host")
        let once = try run(guest.url, into: host)
        try FileManager.default.removeItem(at: host.url.appending(path: "session.xml"))
        host.session = once.session

        let twice = try run(guest.url, into: host)

        #expect(
            twice.session.tracks.map(\.name)
                == ["Host", "Guest", "Host (Guest)", "Guest (Guest)", "Host (2)", "Guest (2)"])

        let pair = try Self.package("Guest")
        try pair.addFile("f1", channels: [sine(seconds: 1, rate: 48_000)])
        try pair.addTrack("a", clip: "A", file: "f1", start: 0, offset: 0, length: 48_000)
        try pair.addTrack("b", clip: "B", file: "f1", start: 0, offset: 0, length: 48_000)
        try pair.session.renameTrack("a", to: "Host")
        try pair.session.renameTrack("b", to: "Host")
        try pair.session.write(to: pair.url)
        try target.session.addTrack("x", name: "Host", layout: .mono)
        #expect(try run(pair.url).session.tracks.map(\.name) == ["Host", "Host (Guest)", "Host (2)"])
        let taken = try Self.package("Taken")
        try taken.session.addTrack("x", name: "Host", layout: .mono)
        try taken.session.addTrack("y", name: "Host (2)", layout: .mono)
        #expect(
            try run(pair.url, into: taken).session.tracks.map(\.name) == [
                "Host", "Host (2)", "Host (Guest)", "Host (3)",
            ])

        let callSource = try Self.callPackage("Guest 2")
        let onlyHost = try Self.package("OnlyHost")
        try onlyHost.session.addTrack("x", name: "Host", layout: .mono)
        #expect(
            try run(callSource.url, into: onlyHost).session.tracks.map(\.name) == ["Host", "Host (Guest 2)", "Guest"])
    }

    /// C2: each named file gets one copy under a new ID; the target file of the same ID and an unnamed file stay.
    @Test func importCopiesOnlyNamedFilesUnderNewIDs() throws {
        let source = try Self.package("Guest")
        try source.addFile("take1-t1", channels: [sine(seconds: 1, rate: 48_000, frequency: 440)])
        try source.addFile("unused", channels: [sine(seconds: 1, rate: 48_000)])
        try source.addTrack("t1", clip: "A", file: "take1-t1", start: 0, offset: 0, length: 48_000)
        try source.session.write(to: source.url)
        try target.addFile("take1-t1", channels: [[Float](repeating: 0, count: 24_000)])
        let targetBytes = FileManager.default.contents(atPath: target.url.appending(path: "Clips/take1-t1.wav").path)

        let result = try run(source.url)

        let added = Set(result.session.files.keys).subtracting(target.session.files.keys)
        #expect(added.count == 1, "the pool grows by the named count only")
        let id = try #require(added.first)
        #expect(clips(result, 0).map(\.file) == [id])
        let path = try #require(result.session.files[id]?.path)
        #expect(
            FileManager.default.contents(atPath: target.url.appending(path: "Clips/\(path)").path)
                == FileManager.default.contents(atPath: source.url.appending(path: "Clips/take1-t1.wav").path))
        #expect(result.session.files["take1-t1"] == target.session.files["take1-t1"])
        #expect(
            FileManager.default.contents(atPath: target.url.appending(path: "Clips/take1-t1.wav").path) == targetBytes)
        #expect(try names(target).count == 2, "no copy of the unused file")
    }

    /// C3: 44 100 Hz into 48 000 Hz converts each file and scales clip edges and markers.
    @Test func importAtAnotherRateConvertsAndScales() throws {
        let source = try Self.package("Guest", rate: 44_100)
        try source.addFile("f1", channels: [sine(seconds: 1, rate: 44_100)])
        try source.addTrack("t1", clip: "A", file: "f1", start: 44_100, offset: 0, length: 44_100)
        try source.session.setMarker(Marker(id: "m", name: "Half", position: 22_050, kind: .marker))
        try source.session.write(to: source.url)

        let result = try run(source.url, markers: true)

        #expect(clips(result, 0).map(\.start) == [48_000])
        let file = try #require(clips(result, 0).first?.file)
        let path = try #require(result.session.files[file]?.path)
        #expect(
            try AVAudioFile(forReading: target.url.appending(path: "Clips/\(path)")).fileFormat.sampleRate == 48_000)
        #expect(result.session.sortedMarkers.map(\.position) == [24_000])
    }

    /// C5: markers come only when asked, with new IDs, at the position plus `at`; out-of-range ones are counted.
    @Test func markersComeOnlyWhenAsked() throws {
        let source = try Self.package("Guest")
        try source.addFile("f1", channels: [sine(seconds: 2, rate: 48_000)])
        try source.addTrack("t1", clip: "A", file: "f1", start: 0, offset: 0, length: 96_000)
        let url = try WebURL("https://example.com/part")
        try source.session.setMarker(Marker(id: "m", name: "Intro", position: 1_000, kind: .marker))
        try source.session.setMarker(Marker(id: "c", name: "Part", position: 60_000, kind: .chapter, url: url))
        try source.session.write(to: source.url)
        try target.session.setMarker(Marker(id: "own", name: "Own", position: 5, kind: .marker))

        #expect(try run(source.url).session.markers == target.session.markers)

        let all = try run(source.url, markers: true)
        let new = all.session.sortedMarkers.filter { $0.id != "own" }
        #expect(new.map(\.name) == ["Intro", "Part"] && new.map(\.kind) == [.marker, .chapter])
        #expect(new.map(\.position) == [1_000, 60_000] && new.map(\.url) == [nil, url])
        #expect(Set(new.map(\.id)).isDisjoint(with: ["m", "c"]) && all.markers == new.map(\.id))
        #expect(new.allSatisfy { $0.image == nil } && all.leftOutMarkers == 0)

        let cut = try run(source.url, at: -48_000, markers: true)
        #expect(cut.session.sortedMarkers.filter { $0.id != "own" }.map(\.position) == [12_000])
        #expect(cut.leftOutMarkers == 1)

        let short = try Self.package("Short")
        try short.addFile("f1", channels: [[Float](repeating: 0, count: 100)])
        try short.addTrack("t1", clip: "A", file: "f1", start: 0, offset: 0, length: 100)
        try short.session.setMarker(Marker(id: "a", name: "Kept", position: 400, kind: .marker))
        try short.session.setMarker(Marker(id: "b", name: "Over", position: 1_000, kind: .marker))
        try short.session.write(to: short.url)
        let high = try run(short.url, at: (1 << 40) - 500, markers: true)
        #expect(high.session.sortedMarkers.filter { $0.id != "own" }.map(\.position) == [Frames((1 << 40) - 100)])
        #expect(high.leftOutMarkers == 1)
    }

    /// C6: the words of a copied file come with it, on the new file ID.
    @Test func importBringsTheWordsOfTheCopiedFiles() throws {
        let source = try Self.package("Guest")
        try source.addFile("f1", channels: [sine(seconds: 1, rate: 48_000)])
        try source.addTrack("t1", clip: "A", file: "f1", start: 0, offset: 0, length: 48_000)
        let words = #"{"words":[{"word":"one","start":0.5,"end":0.75}]}"#
        try source.session.importTranscript(TranscriptFile(data: Data(words.utf8)), name: "t", track: "t1", at: 0)
        try source.session.write(to: source.url)
        try target.addFile("f1", channels: [[Float](repeating: 0, count: 100)])

        let result = try run(source.url)

        let shown = result.session.words(on: result.tracks)
        #expect(shown.map(\.text) == ["one"] && shown.map(\.range) == [24_000..<36_000])
        let clip = try #require(shown.first?.occurrence.clip)
        #expect(result.session.clip(clip)?.clip.file != "f1")
    }

    /// C8: a cancel after the first copy leaves no new name in `Clips/`.
    @Test func aCancelLeavesNoNewFile() throws {
        let source = try Self.package("Guest")
        try source.addFile("f1", channels: [sine(seconds: 1, rate: 48_000)])
        try source.addFile("f2", channels: [sine(seconds: 1, rate: 48_000)])
        try source.addTrack("t1", clip: "A", file: "f1", start: 0, offset: 0, length: 48_000)
        try source.addTrack("t2", clip: "B", file: "f2", start: 0, offset: 0, length: 48_000)
        try source.session.write(to: source.url)
        let before = try names(target)
        let flag = Flag()

        #expect(throws: SessionImportError.paste(.cancelled)) {
            try run(source.url, progress: { if $0 >= 0.5 { flag.set() } }, isCancelled: { flag.value })
        }
        #expect(try names(target) == before)
    }

    /// C8: `made` lists each renamed WAV, so a caller can remove them at a cancel before the save.
    @Test func madeListsEachRenamedFile() throws {
        let source = try Self.package("Guest")
        try source.addFile("f1", channels: [sine(seconds: 1, rate: 48_000)])
        try source.addFile("f2", channels: [sine(seconds: 1, rate: 48_000)])
        try source.addTrack("t1", clip: "A", file: "f1", start: 0, offset: 0, length: 48_000)
        try source.addTrack("t2", clip: "B", file: "f2", start: 0, offset: 0, length: 48_000)
        try source.session.write(to: source.url)
        let before = Set(try names(target))

        let result = try run(source.url)

        #expect(Set(result.made.map(\.lastPathComponent)) == Set(try names(target)).subtracting(before))
        #expect(
            result.made.count == 2 && result.made.allSatisfy { $0.deletingLastPathComponent().path.hasSuffix("Clips") })
    }
}
