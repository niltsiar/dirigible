import Foundation
import Testing

@testable import DirigibleCore

/// F22: the bins of a session in `session.xml` at `binSessionVersion` (run `2026-10-28-favorites-bins`,
/// criteria C1 to C7, C33, and C34).
struct BinTests {
    static let firstRide = envelope([(2_000, -3), (8_000, 2.5)])
    static let secondRide = envelope([(2_000, -6)])
    static let thirdRide = envelope([(3_000, 1.25)])

    /// Host (mono, clip "c1" on "f1"), Guest (stereo, clip "c2" on "f2"), and Music (mono): clip "A" on
    /// "fs" and clip "B" on "fr", a render of "fs", with a crossfade at their join. "A" has a gain and an
    /// envelope point, "B" a fade-out and `firstRide`. "f1" has transcript words.
    static func session() throws -> Session {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "f1", path: "host.wav", layout: .mono, length: 480_000))
        try session.addFile(AudioFile(id: "f2", path: "guest.wav", layout: .stereo, length: 480_000))
        try session.addFile(AudioFile(id: "fs", path: "bed.wav", layout: .mono, length: 100_000))
        let origin = RenderOrigin(source: "fs", offset: 0, treatment: Treatment(.noise(.standard)), addedGain: .zero)
        try session.addFile(AudioFile(id: "fr", path: "bed NR.wav", layout: .mono, length: 100_000, origin: origin))
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.addTrack("t2", name: "Guest", layout: .stereo)
        try session.addTrack("t3", name: "Music", layout: .mono)
        try session.place(Clip(id: "c1", file: "f1", start: 0, offset: 0, length: 96_000), on: "t1")
        try session.place(Clip(id: "c2", file: "f2", start: 24_000, offset: 0, length: 48_000), on: "t2")
        try session.place(Clip(id: "A", file: "fs", start: 100_000, offset: 10_000, length: 4_000), on: "t3")
        try session.place(Clip(id: "B", file: "fr", start: 104_000, offset: 20_000, length: 4_000), on: "t3")
        try session.setGain(try #require(Gain(dB: -4.5)), clip: "A")
        try session.setEnvelope([101_000: try #require(Gain(dB: -3))], clip: "A")
        try session.setCrossfades(["A": 960])
        try session.setFades(["B": try #require(Fades(fadeIn: 0, fadeOut: 100))])
        try session.setRides(["B": firstRide])
        session.addWords([(1, 0..<4_800, "hello"), (2, 4_800..<9_600, "world")], file: "f1")
        return session
    }

    /// C1. Two bins with names that XML escapes, a range item of 2 lanes, a clip-set item with each clip
    /// field, and an item in the other bin that holds the same `ClipID` "B" with another ride, while the
    /// track clip "B" has a third ride. The save passes the read-back check, and each item clip keeps
    /// its own ride. Control: the rides of the bin clips keyed by `ClipID` read one ride for both items.
    @Test func roundTripAtBinVersion() throws {
        var session = try Self.session()
        let music = try session.addBin("b1", named: #"Music & <Intro> "1""#)
        let other = try session.addBin("b2", named: "Later > now")
        try session.addItem(try session.excerpt(of: 0..<48_000, on: ["t1", "t2"]), named: "Hello", to: music, id: "i1")
        try session.addItem(try session.excerpt(of: ["A", "B"]), named: "Bed", to: music, id: "i2")
        try session.setRides(["B": Self.secondRide])
        try session.addItem(try session.excerpt(of: ["B"]), named: "Bed", to: other, id: "i3")
        try session.setRides(["B": Self.thirdRide])

        let data = try session.checkedData()
        let read = try Session(xml: data)

        #expect(session.fileVersion == binSessionVersion)
        #expect(String(decoding: data, as: UTF8.self).contains(#"version="\#(binSessionVersion)""#))
        #expect(read.bins == session.bins)
        #expect(read.bins.map(\.name) == [#"Music & <Intro> "1""#, "Later > now"])
        #expect(read.bins.map { $0.items.map(\.id) } == [["i1", "i2"], ["i3"]])
        let range = try #require(read.bins.first?.items.first)
        #expect(range.kind == .range && range.length == 48_000)
        #expect(range.lanes.map(\.source) == ["t1", "t2"] && range.lanes.map(\.layout) == [.mono, .stereo])
        #expect(range.lanes.map(\.name) == ["Host", "Guest"])
        #expect(range.lanes[1].clips.map(\.start) == [24_000] && range.lanes[1].clips.map(\.length) == [24_000])
        let bed = try #require(read.bins.first?.items.last?.lanes.first?.clips)
        #expect(bed.map(\.id) == ["A", "B"] && bed.map(\.start) == [0, 4_000])
        #expect(bed[0].gain == Gain(dB: -4.5) && bed[0].envelope == envelope([(11_000, -3)]))
        #expect(bed[0].crossfades.end == 960 && bed[1].crossfades.start == 960 && bed[1].fades.fadeOut == 100)
        #expect(bed[1].ride == Self.firstRide)
        #expect(read.bins.last?.items.first?.lanes.first?.clips.first?.ride == Self.secondRide)
        #expect(read.clip("B")?.clip.ride == Self.thirdRide)
    }

    /// C1. A ride that only a bin clip holds gets its `<rides>` list, so the save reads back.
    @Test func rideOnlyInABinReadsBack() throws {
        var session = try Self.session()
        let bin = try session.addBin(named: "Bin")
        try session.addItem(try session.excerpt(of: ["B"]), named: "Bed", to: bin)
        try session.removeClips(["A", "B"])

        let read = try Session(xml: try session.checkedData())

        #expect(read.bins.first?.items.first?.lanes.first?.clips.first?.ride == Self.firstRide)
    }

    /// C2. A session with no bin writes the version of its other data; an empty bin raises it.
    @Test func noBinKeepsVersion() throws {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "f", path: "f.wav", layout: .mono, length: 48_000))
        try session.addTrack("t", name: "T", layout: .mono)
        let fades = try #require(Fades(fadeIn: 480, fadeOut: 0))
        try session.place(Clip(id: "c", file: "f", start: 0, offset: 0, length: 4_800, fades: fades), on: "t")
        try session.addBin("b", named: "Empty")
        #expect(session.fileVersion == binSessionVersion, "control: an empty bin has the bin version")

        try session.removeBin("b")

        let text = String(decoding: try session.checkedData(), as: UTF8.self)
        #expect(session.fileVersion == 3)
        #expect(text.contains(#"version="3""#) && !text.contains("<bins"))
    }

    /// C3. `<bins>` in a file below `binSessionVersion` is refused; the same file at the version reads.
    @Test func binsBeforeBinVersionRefused() throws {
        var session = Session(sampleRate: 48_000)
        try session.addBin("b", named: "Bin")
        let text = String(decoding: try session.checkedData(), as: UTF8.self)
        let older = text.replacingOccurrences(
            of: #"version="\#(binSessionVersion)""#, with: #"version="\#(binSessionVersion - 1)""#)
        #expect(older != text)

        #expect(throws: SessionFileError.invalidValue(element: "bins", attribute: "version")) {
            try Session(xml: Data(older.utf8))
        }
        #expect(try Session(xml: Data(text.utf8)).bins.map(\.name) == ["Bin"])
    }

    /// C5. A file that only a bin clip uses is in use; the source of a rendered file that a bin clip
    /// uses stays a source. After the item goes, the file can go.
    @Test func removeFileRefusesBinFile() throws {
        var session = try Self.session()
        let bin = try session.addBin(named: "Bin")
        let item = try session.addItem(try session.excerpt(of: ["B"]), named: "B", to: bin)
        try session.removeClips(["A", "B"])

        #expect(throws: SessionError.fileInUse("fr")) { try session.removeFile("fr") }
        #expect(throws: SessionError.fileIsSource("fs", of: "fr")) { try session.removeFile("fs") }
        try session.removeItem(item)
        try session.removeFile("fr")
        #expect(session.files["fr"] == nil)
    }

    /// C6. The name rules of the four name edits, the trim, a remove with items, a move, and the
    /// refusals of an unknown ID and of a place past the list. A refused edit changes nothing.
    @Test func binEdits() throws {
        var session = try Self.session()
        let first = try session.addBin("b1", named: "  Interviews ")
        let second = try session.addBin("b2", named: "Music")
        let excerpt = try session.excerpt(of: ["c1"])
        try session.addItem(excerpt, named: " Take ", to: first, id: "i1")
        try session.addItem(excerpt, named: "Take", to: first, id: "i2")
        #expect(session.bins.map(\.name) == ["Interviews", "Music"])
        #expect(session.bins[0].items.map(\.name) == ["Take", "Take"])
        let before = session

        for name in ["", "   "] {
            #expect(throws: SessionError.emptyName) { try session.addBin(named: name) }
            #expect(throws: SessionError.emptyName) { try session.renameBin(first, to: name) }
            #expect(throws: SessionError.emptyName) { try session.addItem(excerpt, named: name, to: first) }
            #expect(throws: SessionError.emptyName) { try session.renameItem("i1", to: name) }
        }
        for name in ["Tab\there", "\tLead", "Line\nbreak", "Nul\u{0}"] {
            #expect(throws: SessionError.invalidText(name)) { try session.addBin(named: name) }
            #expect(throws: SessionError.invalidText(name)) { try session.renameBin(first, to: name) }
            #expect(throws: SessionError.invalidText(name)) { try session.addItem(excerpt, named: name, to: first) }
            #expect(throws: SessionError.invalidText(name)) { try session.renameItem("i1", to: name) }
        }
        #expect(throws: SessionError.unknownBin("nope")) { try session.renameBin("nope", to: "X") }
        #expect(throws: SessionError.unknownBin("nope")) { try session.addItem(excerpt, named: "X", to: "nope") }
        #expect(throws: SessionError.unknownBinItem("nope")) { try session.removeItem("nope") }
        #expect(throws: SessionError.binIndexOutOfRange(2)) { try session.moveBin(first, to: 2) }
        #expect(throws: SessionError.binIndexOutOfRange(-1)) { try session.moveBin(first, to: -1) }
        #expect(session == before)

        try session.renameBin(second, to: " Beds ")
        try session.renameItem("i2", to: "Second")
        try session.moveBin(second, to: 0)
        #expect(session.bins.map(\.name) == ["Beds", "Interviews"])
        #expect(session.bins[1].items.map(\.name) == ["Take", "Second"])
        try session.removeBin(first)
        #expect(session.bins.map(\.id) == ["b2"])
        #expect(throws: SessionError.unknownBinItem("i1")) { try session.excerpt(of: BinItemID("i1")) }
    }

    /// C7. The item keeps the kind, the length, and the lanes of the excerpt; `excerpt(of:)` gives the
    /// excerpt again with the pool records also after the source clips are gone. A clip set of "A" alone
    /// keeps its crossfade with no partner, as the excerpt does. An excerpt at another rate, a clip of
    /// another pool, and an excerpt of length 0 are refused.
    @Test func addItemChecks() throws {
        var session = try Self.session()
        let bin = try session.addBin(named: "Bin")
        let range = try session.excerpt(of: 0..<48_000, on: ["t1", "t2"])
        let id = try session.addItem(range, named: "Hello", to: bin)
        try session.removeClips(["c1", "c2"])

        let item = try #require(session.bins.first?.items.first)
        #expect(item.id == id && item.kind == .range && item.length == 48_000 && item.lanes == range.lanes)
        #expect(try session.excerpt(of: id) == range)
        #expect(try session.excerpt(of: id).files == ["f1": session.files["f1"]!, "f2": session.files["f2"]!])
        try session.addItem(try session.excerpt(of: ["A"]), named: "Lone", to: bin)
        #expect(session.bins[0].items.last?.lanes.first?.clips.first?.crossfades.end == 960)

        let before = session
        var slow = Session(sampleRate: 44_100)
        try slow.addFile(AudioFile(id: "g", path: "g.wav", layout: .mono, length: 44_100))
        try slow.addTrack("t", name: "T", layout: .mono)
        try slow.place(Clip(id: "x", file: "g", start: 0, offset: 0, length: 4_410), on: "t")
        #expect(throws: SessionError.otherSampleRate(44_100)) {
            try session.addItem(try slow.excerpt(of: ["x"]), named: "Slow", to: bin)
        }
        var foreign = Session(sampleRate: 48_000)
        try foreign.addFile(AudioFile(id: "f1", path: "other.wav", layout: .mono, length: 480_000))
        try foreign.addTrack("t", name: "T", layout: .mono)
        try foreign.place(Clip(id: "x", file: "f1", start: 0, offset: 0, length: 4_800), on: "t")
        #expect(throws: SessionError.foreignFile("f1")) {
            try session.addItem(try foreign.excerpt(of: ["x"]), named: "Foreign", to: bin)
        }
        let bed = try session.excerpt(of: ["A", "B"])
        #expect(bed.length == 8_000, "control: the clips A and B end at the item end")
        let short = Excerpt(kind: .clips, length: 7_999, lanes: bed.lanes, sampleRate: 48_000, pool: session.files)
        #expect(throws: SessionError.clipPastItemEnd("B")) { try session.addItem(short, named: "Short", to: bin) }
        #expect(throws: SessionError.emptyExcerpt) {
            try session.addItem(try session.excerpt(of: 6_000..<6_000, on: ["t1"]), named: "Empty", to: bin)
        }
        #expect(throws: SessionError.emptyExcerpt) {
            try session.addItem(try session.excerpt(of: [ClipID]()), named: "None", to: bin)
        }
        #expect(session == before)
    }

    /// C7. A used `BinItemID` is refused in any bin, and the session does not change.
    @Test func addItemRefusesUsedID() throws {
        var session = try Self.session()
        let first = try session.addBin(named: "One")
        let second = try session.addBin(named: "Two")
        let excerpt = try session.excerpt(of: ["c1"])
        try session.addItem(excerpt, named: "Take", to: first, id: "i1")
        let before = session

        #expect(throws: SessionError.duplicateID("i1")) {
            try session.addItem(excerpt, named: "Again", to: second, id: "i1")
        }
        #expect(throws: SessionError.duplicateID(first.rawValue)) { try session.addBin(first, named: "Copy") }
        #expect(session == before)
    }

    /// C33. A new episode keeps the bins, the file of a bin clip that no track clip uses, and the
    /// origin source of that file. Control: `filesInUse` over the track clips makes `newEpisode()`
    /// throw `.fileInUse`.
    @Test func newEpisodeKeepsBins() throws {
        var session = try Self.session()
        let bin = try session.addBin(named: "Jingles")
        try session.addItem(try session.excerpt(of: ["B"]), named: "Sting", to: bin)
        try session.removeClips(["A", "B"])

        let new = try session.newEpisode()

        #expect(new.session.bins == session.bins)
        #expect(new.session.files["fr"] == session.files["fr"] && new.session.files["fs"] == session.files["fs"])
        #expect(new.filePaths.contains("Clips/bed NR.wav") && new.filePaths.contains("Clips/bed.wav"))
    }

    /// C34. The reader checks each bin clip as a track clip: a clip of an unknown file, past the end of
    /// its file, of a file with another layout than its lane, over another clip of its lane, or past the
    /// end of its item, and an item of length 0, refuse the file. The same file with no change reads.
    @Test func damagedBinClipRefusedAtRead() throws {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "fb", path: "b.wav", layout: .mono, length: 10_000))
        try session.addTrack("t", name: "Bin lane", layout: .mono)
        try session.place(Clip(id: "X", file: "fb", start: 0, offset: 0, length: 1_000), on: "t")
        try session.place(Clip(id: "Y", file: "fb", start: 1_000, offset: 2_000, length: 500), on: "t")
        let bin = try session.addBin(named: "Bin")
        try session.addItem(try session.excerpt(of: ["X", "Y"]), named: "Two", to: bin)
        try session.removeClips(["X", "Y"])
        let text = String(decoding: try session.checkedData(), as: UTF8.self)
        #expect(try Session(xml: Data(text.utf8)).bins == session.bins)

        let cases: [(String, String, SessionError)] = [
            (#"file="fb""#, #"file="zz""#, .unknownFile("zz")),
            (#"length="1000""#, #"length="20000""#, .clipOutsideFile("X")),
            (#"name="Bin lane" layout="mono""#, #"name="Bin lane" layout="stereo""#, .layoutMismatch("t", .file("fb"))),
            (#"start="1000""#, #"start="500""#, .overlap("Y", "X")),
            (#"length="1500""#, #"length="1499""#, .clipPastItemEnd("Y")),
            (#"length="1500""#, #"length="0""#, .emptyExcerpt),
        ]
        for (old, new, error) in cases {
            let damaged = text.replacingOccurrences(of: old, with: new)
            #expect(damaged != text, "the case changes the file: \(old)")
            #expect(throws: SessionFileError.invalidSession(error)) { try Session(xml: Data(damaged.utf8)) }
        }
    }

    /// The read-back of random bins built through the edits, with names of each character class that
    /// XML escapes, items of ranges and clip sets, and rides on the clips.
    @Test func randomBinsReadBack() throws {
        var random = SplitMix(seed: 20_261_122)
        let words = ["Intro", "A & B", "<tag>", #""quoted""#, "it's", "Gäste 🎙️", "x"]
        let rides = [Self.firstRide, Self.secondRide, Self.thirdRide, .empty]
        let tracks: [TrackID] = ["t3", "t1", "t2"]
        let clips: [ClipID] = ["A", "B", "c2"]
        for round in 0..<20 {
            var session = try Self.session()
            for bin in 0..<Int.random(in: 1...4, using: &random) {
                let id = try session.addBin(named: "\(words.randomElement(using: &random)!) \(bin)")
                for _ in 0..<Int.random(in: 0...4, using: &random) {
                    try session.setRides(["B": rides.randomElement(using: &random)!])
                    let start = Int.random(in: 0..<90_000, using: &random)
                    var picked = clips.filter { _ in Bool.random(using: &random) }
                    if picked.isEmpty { picked = [clips.randomElement(using: &random)!] }
                    let excerpt =
                        Bool.random(using: &random)
                        ? try session.excerpt(
                            of: Frames(start)..<Frames(start + Int.random(in: 1...30_000, using: &random)),
                            on: tracks.shuffled(using: &random))
                        : try session.excerpt(of: picked)
                    try session.addItem(excerpt, named: words.randomElement(using: &random)!, to: id)
                }
            }
            let read = try Session(xml: try session.checkedData())
            #expect(read.bins == session.bins, "round \(round)")
        }
    }
}
