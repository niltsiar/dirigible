import AVFoundation
import AppKit
import DirigibleCore
import DirigibleTimeline
import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleAudio

/// Tools > Find Silences... and the Silences tab on a real session window (decision 0066, criteria
/// C5, C21, C22, C29, C33 to C38; the lane shade and the on-screen look are manual checks). Each
/// fixture track is mono at 48 kHz with one clip from frame 0 and is muted, so a play is silent
/// and the scan ignores the mute. `voice` has the silences A at 96 000 ..< 216 000 and B at
/// 288 000 ..< 384 000 of a 480 000 frame session; with the keep of 500 ms their cuts are
/// 108 000 ..< 204 000 and 300 000 ..< 372 000.
@Suite(.serialized) @MainActor struct SilencesInspectorTests {
    enum Part {
        case tone(Double)
        case quiet(Double)
        /// A constant sample, so a window has this RMS level in dBFS.
        case floor(Double, dBFS: Double)
    }

    static let voice: [Part] = [.tone(2), .quiet(2.5), .tone(1.5), .quiet(2), .tone(2)]
    static let silenceA: Range<Frames> = 96_000..<216_000
    static let silenceB: Range<Frames> = 288_000..<384_000
    static let cutA: Range<Frames> = 108_000..<204_000
    static let cutB: Range<Frames> = 300_000..<372_000

    let folder: TemporaryFolder
    let defaults: UserDefaults
    let suite = "SilencesInspectorTests.\(UUID().uuidString)"
    let app: AppDelegate
    let hal = CountingHAL()

    init() throws {
        folder = try TemporaryFolder()
        defaults = try #require(UserDefaults(suiteName: suite))
        app = AppDelegate(recordings: nil, defaults: defaults)
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    static func samples(_ parts: [Part]) -> [Float] {
        var samples: [Float] = []
        for part in parts {
            switch part {
            case .tone(let seconds):
                let start = samples.count
                samples += (0..<Int((seconds * 48_000).rounded())).map {
                    0.5 * Float(sin(2 * Double.pi * 1_000 * Double(start + $0) / 48_000))
                }
            case .quiet(let seconds): samples += Array(repeating: 0, count: Int((seconds * 48_000).rounded()))
            case .floor(let seconds, let dBFS):
                samples += Array(repeating: Float(pow(10, dBFS / 20)), count: Int((seconds * 48_000).rounded()))
            }
        }
        return samples
    }

    /// A package with a muted track `t<n>` for each list of parts (the clip `c<n>` of the file `f<n>`),
    /// routed to `device`, and with `words` (start, end, text in seconds) on `t1`.
    func package(
        _ name: String = "a", tracks: [[Part]] = [voice], words: [(Double, Double, String)] = [],
        device: String = "duo"
    ) async throws -> URL {
        let url = folder.url.appending(path: "\(name).dirigible")
        let data = tracks.map(Self.samples)
        try await Task.detached {
            try Session.create(at: url, sampleRate: 48_000)
            var session = Session(sampleRate: 48_000)
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
            for (index, samples) in data.enumerated() {
                let (file, track) = (FileID("f\(index + 1)"), TrackID("t\(index + 1)"))
                let buffer = try #require(
                    AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
                buffer.frameLength = AVAudioFrameCount(samples.count)
                samples.withUnsafeBufferPointer {
                    buffer.floatChannelData?[0].update(from: $0.baseAddress!, count: samples.count)
                }
                let writer = try ClipWriter(
                    url: url.appending(path: "\(clipsFolderName)/f\(index + 1).wav"), file: "f\(index + 1).wav",
                    format: format)
                try writer.write(buffer)
                try writer.close()
                let length = Frames(samples.count)
                try session.addFile(AudioFile(id: file, path: "f\(index + 1).wav", layout: .mono, length: length))
                try session.addTrack(track, name: "T\(index + 1)", layout: .mono)
                try session.setRoute(Route.device(uid: device, channels: .mono(1)), track: track)
                try session.place(
                    Clip(id: ClipID("c\(index + 1)"), file: file, start: 0, offset: 0, length: length), on: track)
            }
            try session.setMuted(true, tracks: session.tracks.map(\.id))
            if !words.isEmpty {
                let json =
                    #"{"words":["#
                    + words.map { #"{"word":" \#($0.2)","start":\#($0.0),"end":\#($0.1)}"# }.joined(separator: ",")
                    + "]}"
                try session.importTranscript(
                    try TranscriptFile(data: Data(json.utf8)), name: "Speaker", track: "t1", at: 0)
            }
            try session.write(to: url)
        }.value
        return url
    }

    func open(_ url: URL) async throws -> (SessionWindow, Studio) {
        let (model, studio, _, _) = try await openLanes(app, url)
        return (model, studio)
    }

    func rows(_ model: SessionWindow) -> [SilenceReview.Row] { model.silences.review?.rows ?? [] }

    /// C5a to C5g, one case each: the item scans the whole session or the range, stops a play, is
    /// off during a job and a take, scans again into the one list, scans with the focus in the keep
    /// field, and opens the inspector on the Silences tab.
    @Test func findSilencesInEachStartState() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, studio) = try await open(try await package())

        // C5a: no selection, and a clip set, scan the whole session.
        await model.findSilences()
        #expect(model.silences.review?.scan.range == 0..<480_000, "C5a: \(String(describing: model.silences.review))")
        #expect(rows(model).map(\.silence) == [Self.silenceA, Self.silenceB], "C5a: \(rows(model))")
        let clip = try #require(studio.session.tracks.first?.clips.first)
        model.timeline.selection = .clips(try #require(ClipSet([clip.id])))
        await model.findSilences()
        #expect(model.silences.review?.scan.range == 0..<480_000, "C5a: a clip set scans a part")

        // C5b: a range gives the silences that meet it, each with its whole extent.
        model.timeline.selection = .range(Marks(inPoint: 100_000, outPoint: 150_000, tracks: ["t1"]))
        await model.findSilences()
        #expect(model.silences.review?.scan.range == 100_000..<150_000, "C5b")
        #expect(rows(model).map(\.silence) == [Self.silenceA], "C5b: \(rows(model))")
        model.timeline.selection = .none

        // C5c: a play stops, then the scan runs.
        await studio.perform(.seek(.start))
        await studio.perform(.playStop)
        try #require(studio.playback != .stopped, "the play runs")
        await model.findSilences()
        #expect(studio.playback == .stopped, "C5c: the play goes on")
        #expect(rows(model).count == 2, "C5c: \(rows(model))")

        // C5d: a level runs, so the item is off and a call through the window scans nothing.
        model.silences.review = nil
        let gate = AsyncGate()
        studio.environment.beforeFinalize = { await gate.wait() }
        let leveling = Task { await model.level(.eachClip) }
        await gate.entered()
        #expect(!model.isOn(.findSilences), "C5d: a level runs and the item is on")
        await model.findSilences()
        #expect(model.silences.review == nil, "C5d: a level runs and the window scanned")
        gate.open()
        await leveling.value
        studio.environment.beforeFinalize = {}

        // C5g: the inspector is closed, or shows another tab: the item opens the Silences tab first.
        model.selectInspectorTab(.clip)
        model.toggleInspector()
        #expect(!model.showsInspector, "the inspector stays open")
        await model.findSilences()
        #expect(model.showsInspector && model.inspectorTab == .silences, "C5g: closed inspector")
        model.selectInspectorTab(.episode)
        await model.findSilences()
        #expect(model.inspectorTab == .silences, "C5g: Episode tab")

        // C5e: the tab shows a list: the item scans again into the same list.
        model.setSilenceAction(.skip, rows: [0])
        await model.findSilences()
        #expect(rows(model).map(\.action) == [.shorten, .shorten], "C5e: \(rows(model))")

        // C5f: the keep field has the focus: the item still scans.
        model.silences.review = nil
        model.silences.keepFocused = true
        #expect(model.isOn(.findSilences), "C5f: the item is off")
        await model.findSilences()
        #expect(rows(model).count == 2, "C5f: no scan")
        model.silences.keepFocused = false

        // C5d: a take records, so the item is off. After the close it is off too.
        studio.environment = hal.environment
        await model.record()
        #expect(studio.transport == .recording(take: 1), "\(studio.transport)")
        #expect(!model.isOn(.findSilences), "C5d: a take records and the item is on")
        await hal.feed(seconds: 0.5)
        await model.stop()
        await until("the take finalizes") { studio.transport == .idle }
        #expect(model.isOn(.findSilences), "C5d: after the take the item is off")
        await model.close()
        #expect(!model.isOn(.findSilences), "C5d: the window settles and the item is on")
    }

    /// C37: a row whose cut holds a transcript word, or has sound on a track outside the scan,
    /// starts as Mark with its reason; a row with no warning starts as Shorten with no reason.
    @Test func aRowWithAWarningStartsAsMarkAndSaysWhy() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        // The word is in the cut of A. Track t2 has sound at 7.0 s to 7.5 s, in the cut of B.
        let music: [Part] = [.quiet(7), .tone(0.5), .quiet(2.5)]
        let url = try await package(tracks: [Self.voice, music], words: [(3.5, 3.8, "Hello")])
        let (model, _) = try await open(url)

        // Both tracks scanned: the sound of t2 splits B, and its first part has no warning.
        await model.scanSilences()
        let all = rows(model)
        #expect(all.map(\.silence) == [Self.silenceA, 288_000..<336_000], "\(all)")
        #expect(all.map(\.reason) == [.word, nil], "\(all)")
        #expect(all.map(\.action) == [.mark, .shorten], "a row with a warning starts as Shorten: \(all)")

        // t2 left out: B is a silence of t1, and the sound of t2 is in its cut.
        model.silences.settings.unchecked = ["t2"]
        await model.scanSilences()
        let outside = rows(model)
        #expect(outside.map(\.silence) == [Self.silenceA, Self.silenceB], "\(outside)")
        #expect(outside.map(\.reason) == [.word, .soundOutsideScan], "\(outside)")
        #expect(outside.map(\.action) == [.mark, .mark], "\(outside)")
        let review = try #require(model.silences.review)
        let english = try stringsTable("en")
        #expect(
            review.label(of: outside[1], locale: Locale(identifier: "en"), table: { english[$0.rawValue]! })
                == "Silence at 0:06, 2.0 seconds, Mark, Sound on a track outside the scan")
        await model.close()
    }

    /// C21: a click on a row sets the range to the silence and the playhead 2 s before it, or at
    /// frame 0 for a silence that starts under 2 s.
    @Test func aRowClickSelectsTheSilence() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let early: [Part] = [.tone(0.5), .quiet(1.5), .tone(2)]
        let (model, studio) = try await open(try await package())
        await model.scanSilences()
        model.selectSilences([1])
        await model.settleTransport()
        #expect(model.timeline.selection.marks?.selection(in: studio.session)?.range == Self.silenceB, "the range")
        #expect(studio.playhead == 192_000, "2 s before 288 000: \(studio.playhead)")
        await studio.perform(.seek(.frame(150_000)))
        model.selectSilences([0, 1])
        await model.settleTransport()
        #expect(studio.playhead == 150_000, "two rows moved the playhead")
        await model.close()

        let (second, secondStudio) = try await open(try await package("early", tracks: [early]))
        await second.scanSilences()
        #expect(second.silences.review?.rows.map(\.silence) == [24_000..<96_000], "\(rows(second))")
        await secondStudio.perform(.seek(.frame(150_000)))
        second.selectSilences([0])
        await second.settleTransport()
        #expect(secondStudio.playhead == 0, "a silence under 2 s from the start: \(secondStudio.playhead)")
        await second.close()
    }

    /// C22: the keep stays under the minimum: 999 ms is accepted and 1 000 ms is refused with the
    /// minimum of 1 s, and a refused keep turns Scan and Apply off. Apply is off with no row to
    /// apply. Typing in the keep field edits no session.
    @Test func theKeepStaysUnderTheMinimum() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let (model, studio) = try await open(try await package())
        let before = studio.session
        model.silences.setKeep("999")
        #expect(!model.silences.settings.keepRefused && model.canScanSilences, "999 ms")
        await model.scanSilences()
        #expect(model.canApplySilences, "a list with two rows")
        model.silences.setKeep("1000")
        #expect(model.silences.settings.keepRefused, "1000 ms")
        #expect(!model.canScanSilences && !model.canApplySilences, "a refused keep leaves Scan or Apply on")
        for text in ["", "abc", "-1"] {
            model.silences.setKeep(text)
            #expect(model.silences.settings.keepRefused, "\(text)")
        }
        model.silences.setKeep("999")
        model.silences.review = nil
        await model.scanSilences()
        model.setSilenceAction(.skip, rows: [0, 1])
        #expect(!model.canApplySilences, "every row is Skip")
        model.silences.settings.minimum = 30_000
        await model.scanSilences()
        #expect(rows(model).isEmpty && !model.canApplySilences, "a list with no row")
        #expect(studio.session == before && !studio.canUndo, "typing or a scan edited the session")
        await model.close()
    }
}
