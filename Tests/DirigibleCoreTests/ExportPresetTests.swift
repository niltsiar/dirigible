import Foundation
import Testing

@testable import DirigibleCore

/// The export preset values and the edits of the preset list (decision 0080, E2 and E3).
struct ExportPresetTests {
    static let mp3 = try! PresetOptions(format: .mp3(.k128), layout: .mono, rate: .hz44100, loudness: .podcast)
    static let wav = try! PresetOptions(format: .wav(.bits16), layout: .stereo, rate: .session, loudness: nil)

    static func preset(_ name: String, _ options: PresetOptions = mp3) throws(SessionError) -> ExportPreset {
        ExportPreset(name: try PresetName(name), options: options)
    }

    static func names(_ session: Session) -> [String] { session.exportPresets.map(\.name.text) }

    /// A session read from a file whose `<exportPresets>` holds `presets`: the only way to a stored
    /// name that the edits refuse.
    static func stored(_ presets: String) throws -> Session {
        let list = "<exportPresets>\(presets)</exportPresets>"
        return try Session(xml: Data(document(version: String(presetSessionVersion), recording: list).utf8))
    }

    static func element(_ name: String) -> String {
        #"<preset name="\#(name)" format="mp3" bitRate="128" channels="mono" rate="44100" loudness="podcast"/>"#
    }

    /// E2: 1 to 64 Unicode scalars, no space at either end, and no control character. A built-in ID is
    /// a valid name: `PresetName` knows no built-in. The limit counts scalars, not characters, because
    /// the character count of a combining sequence depends on the Unicode tables of the OS.
    @Test(arguments: [
        (String(repeating: "a", count: 64), true), (String(repeating: "a", count: 65), false),
        (String(repeating: "\u{E9}", count: 64), true), (String(repeating: "\u{E9}", count: 65), false),
        (String(repeating: "e\u{301}", count: 32), true), (String(repeating: "e\u{301}", count: 33), false),
        ("", false), (" Show", false), ("Show ", false), ("Sh\u{7}ow", false), ("Sh\u{85}ow", false),
        ("Show\u{FFFF}", false), ("master", true), ("Podcast", true), ("Show/Feed", true), ("Show & Tell", true),
    ])
    func aNameHasOneTo64ScalarsAndNoSpaceAtAnEnd(text: String, valid: Bool) {
        if valid {
            #expect((try? PresetName(text))?.text == text, "\(text.debugDescription)")
        } else {
            #expect(throws: SessionError.invalidPresetName(text), "\(text.debugDescription)") {
                try PresetName(text)
            }
        }
    }

    /// E2: the name keeps its exact text, and both cases have one key: the case-folded text.
    @Test func aNameKeepsItsCaseAndTheKeyFoldsIt() throws {
        let (upper, lower) = (try PresetName("Show"), try PresetName("show"))
        #expect(upper != lower)
        #expect(upper.key == lower.key && upper.key == "show")
        #expect(try PresetName("ÉCLAT").key == PresetName("éclat").key)
        #expect(try PresetName("Show 2").key != upper.key)
    }

    /// E2: `.floatCAF`, the format of `dirigible render`, is not a preset format.
    @Test func aPresetCannotHaveTheRenderFormat() throws {
        #expect(throws: SessionError.invalidPreset) {
            try PresetOptions(format: .floatCAF, layout: .stereo, rate: .session, loudness: nil)
        }
        #expect(
            try PresetOptions(format: .flac(.bits24), layout: .stereo, rate: .hz48000, loudness: .ebu).rate == .hz48000)
    }

    /// E2 and U10: the stored IDs and the options of the built-in presets.
    @Test func eachBuiltInHasItsIDAndItsOptions() throws {
        #expect(BuiltInPreset.allCases.map(\.rawValue) == ["master", "podcast"])
        #expect(
            BuiltInPreset.master.options
                == (try PresetOptions(format: .wav(.bits24), layout: .stereo, rate: .session, loudness: nil)))
        #expect(BuiltInPreset.podcast.options == Self.mp3)
    }

    /// E3: an add goes at the end, and a rename puts the preset in the place of the old one.
    @Test func aRenameKeepsThePlace() throws {
        var session = Session(sampleRate: 48_000)
        for name in ["A", "B", "C"] { try session.setExportPreset(Self.preset(name)) }
        #expect(Self.names(session) == ["A", "B", "C"])

        try session.setExportPreset(Self.preset("D", Self.wav), replacing: PresetName("B"))

        #expect(Self.names(session) == ["A", "D", "C"])
        #expect(session.exportPresets[1].options == Self.wav)
    }

    /// E3: an add or a rename to a name whose key another session preset has throws, and the list
    /// does not change.
    @Test func aNameOfAnotherKeyIsTaken() throws {
        var session = Session(sampleRate: 48_000)
        try session.setExportPreset(Self.preset("Show"))
        try session.setExportPreset(Self.preset("Feed"))
        let before = session

        #expect(throws: SessionError.presetNameTaken("show")) { try session.setExportPreset(Self.preset("show")) }
        #expect(throws: SessionError.presetNameTaken("SHOW")) {
            try session.setExportPreset(Self.preset("SHOW"), replacing: PresetName("Feed"))
        }
        #expect(session == before)
    }

    /// E3: a built-in ID is taken for an add and for a rename, in each case.
    @Test func aBuiltInIDIsTaken() throws {
        var session = Session(sampleRate: 48_000)
        try session.setExportPreset(Self.preset("Show"))
        let before = session

        #expect(throws: SessionError.presetNameTaken("MASTER")) { try session.setExportPreset(Self.preset("MASTER")) }
        #expect(throws: SessionError.presetNameTaken("Podcast")) {
            try session.setExportPreset(Self.preset("Podcast"), replacing: PresetName("Show"))
        }
        #expect(session == before)
    }

    /// E3: a case-only rename changes the session, so it is one undo step, and the file keeps the new
    /// text.
    @Test func aCaseOnlyRenameIsOneUndoStepAndIsSaved() throws {
        var start = Session(sampleRate: 48_000)
        try start.setExportPreset(Self.preset("show"))
        var history = History(start)

        try history.edit { (session: inout Session) throws(SessionError) in
            try session.setExportPreset(Self.preset("Show"), replacing: PresetName("show"))
        }

        #expect(history.canUndo && history.revision == 1)
        #expect(Self.names(history.session) == ["Show"])
        #expect(Self.names(try Session(xml: history.session.checkedData())) == ["Show"])
        try history.undo()
        #expect(Self.names(history.session) == ["show"])
    }

    /// E3: an undo of an add, an edit, and a remove gives the list before each.
    @Test func undoRestoresTheList() throws {
        var history = History(Session(sampleRate: 48_000))
        try history.edit { (session: inout Session) throws(SessionError) in
            try session.setExportPreset(Self.preset("A"))
        }
        try history.edit { (session: inout Session) throws(SessionError) in
            try session.setExportPreset(Self.preset("B", Self.wav))
        }
        try history.edit { (session: inout Session) throws(SessionError) in
            try session.setExportPreset(Self.preset("A", Self.wav), replacing: PresetName("A"))
        }
        try history.edit { (session: inout Session) throws(SessionError) in
            try session.removeExportPreset(PresetName("B"))
        }
        #expect(history.session.exportPresets == [try Self.preset("A", Self.wav)])

        try history.undo()
        #expect(history.session.exportPresets == [try Self.preset("A", Self.wav), try Self.preset("B", Self.wav)])
        try history.undo()
        #expect(history.session.exportPresets == [try Self.preset("A"), try Self.preset("B", Self.wav)])
        try history.undo()
        #expect(history.session.exportPresets == [try Self.preset("A")])
        try history.undo()
        #expect(history.session.exportPresets.isEmpty)
    }

    /// E3: a remove or a replace of a name that the session does not store throws, and the list does
    /// not change. The lookup is by exact name.
    @Test func anUnknownPresetThrows() throws {
        var session = Session(sampleRate: 48_000)
        try session.setExportPreset(Self.preset("Show"))
        let before = session

        #expect(throws: SessionError.unknownPreset("show")) { try session.removeExportPreset(PresetName("show")) }
        #expect(throws: SessionError.unknownPreset("Feed")) {
            try session.setExportPreset(Self.preset("Feed"), replacing: PresetName("Feed"))
        }
        #expect(session == before)
        try session.removeExportPreset(PresetName("Show"))
        #expect(session.exportPresets.isEmpty)
    }

    /// E3: the list is the built-ins, then the session presets. The lookup folds the case and takes
    /// the first match with the session presets first, so a stored "Master" hides the built-in.
    @Test func theSessionPresetWinsTheLookup() throws {
        let session = try Self.stored(Self.element("Master") + Self.element("Show") + Self.element("show"))
        let master = try PresetName("Master")

        #expect(
            session.allExportPresets.map { $0.ref } == [
                .builtIn(.master), .builtIn(.podcast), .session(master), .session(try PresetName("Show")),
                .session(try PresetName("show")),
            ])
        #expect(session.exportPreset(named: "MASTER")?.ref == .session(master))
        #expect(session.exportPreset(named: "master")?.options == Self.mp3)
        #expect(session.exportPreset(named: "Podcast")?.ref == .builtIn(.podcast))
        #expect(session.exportPreset(named: "SHOW")?.ref == .session(try PresetName("Show")))
        #expect(session.exportPreset(named: "Feed") == nil)
        #expect(Session(sampleRate: 48_000).exportPreset(named: "master")?.ref == .builtIn(.master))
    }

    /// E3: an edit under its own name has no collision check, so a stored preset whose key a
    /// built-in has can change its options and the case of its name.
    @Test func aStoredPresetWithABuiltInKeyCanChangeItsOptions() throws {
        var session = try Self.stored(Self.element("master"))

        try session.setExportPreset(Self.preset("master", Self.wav), replacing: PresetName("master"))
        #expect(session.exportPresets == [try Self.preset("master", Self.wav)])
        try session.setExportPreset(Self.preset("Master", Self.wav), replacing: PresetName("master"))
        #expect(Self.names(session) == ["Master"])
    }

    /// E3: the collision rule compares keys of names and built-in IDs, not the display texts.
    @Test func aSessionPresetMayShowABuiltInDisplayText() throws {
        var session = Session(sampleRate: 48_000)

        try session.setExportPreset(Self.preset("Master (WAV)", Self.wav))
        try session.setExportPreset(Self.preset("Podcast (MP3)"))

        #expect(Self.names(session) == ["Master (WAV)", "Podcast (MP3)"])
    }
}
