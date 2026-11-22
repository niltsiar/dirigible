import Foundation
import Testing

@testable import DirigibleCore

/// The `<exportPresets>` element of `session.xml` at `presetSessionVersion` (decision 0080, E4).
struct ExportPresetFileTests {
    func read(_ presets: String, version: Int = presetSessionVersion) throws(SessionFileError) -> Session {
        let list = "<exportPresets>\(presets)</exportPresets>"
        return try Session(xml: Data(document(version: String(version), recording: list).utf8))
    }

    func text(_ session: Session) throws -> String { String(decoding: try session.checkedData(), as: UTF8.self) }

    /// E4: presets of each format, layout, rate, and loudness read back equal and in their order.
    @Test func twoPresetsReadBackEqual() throws {
        var session = Session(sampleRate: 48_000)
        let options = [
            try PresetOptions(format: .mp3(.k96), layout: .mono, rate: .hz44100, loudness: .podcast),
            try PresetOptions(format: .wav(.bits16), layout: .stereo, rate: .session, loudness: nil),
            try PresetOptions(format: .flac(.bits24), layout: .stereo, rate: .hz48000, loudness: .ebu),
            try PresetOptions(format: .aac(.k256), layout: .mono, rate: .session, loudness: .atsc),
        ]
        for (index, option) in options.enumerated() {
            try session.setExportPreset(ExportPreset(name: PresetName(#"Feed & "Show" \#(index)"#), options: option))
        }

        let read = try Session(xml: try session.checkedData())

        #expect(read == session)
        #expect(read.exportPresets.map(\.options) == options)
        let written = try text(session)
        #expect(written.contains(#"version="\#(presetSessionVersion)""#), "\(written)")
        let first =
            #"<preset name="Feed &amp; &quot;Show&quot; 0" format="mp3" bitRate="96" channels="mono" rate="44100" "#
            + #"loudness="podcast"></preset>"#
        #expect(written.contains(first), "\(written)")
        #expect(written.contains(#"format="wav" bits="16" channels="stereo" rate="session"></preset>"#), "\(written)")
    }

    /// E4 and 0024 P6: a session with no preset writes no element and the version of its other data;
    /// a preset raises it to `presetSessionVersion`.
    @Test func aSessionWithNoPresetKeepsItsVersion() throws {
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t1", name: "Host", layout: .mono)
        try session.setRole(.dialogue, tracks: ["t1"])
        #expect(session.fileVersion == 11)
        #expect(try !text(session).contains("exportPresets"))

        try session.setExportPreset(ExportPreset(name: PresetName("Show"), options: ExportPresetTests.mp3))
        #expect(session.fileVersion == presetSessionVersion)
        #expect(presetSessionVersion > driftSessionVersion)
        #expect(try text(session).contains("<exportPresets>"))
    }

    /// E4: a stored name that is the ID of a built-in reads back: the reader knows no built-in.
    @Test func aStoredPresetWithABuiltInIDReadsBack() throws {
        let session = try read(ExportPresetTests.element("master") + ExportPresetTests.element("Podcast"))

        #expect(ExportPresetTests.names(session) == ["master", "Podcast"])
        #expect(try Session(xml: session.checkedData()) == session)
    }

    /// E4: two stored names of one key read back in their order: the reader never checks the key.
    @Test func twoStoredPresetsOfOneKeyReadBack() throws {
        let session = try read(ExportPresetTests.element("Show") + ExportPresetTests.element("show"))

        #expect(ExportPresetTests.names(session) == ["Show", "show"])
        #expect(try Session(xml: session.checkedData()) == session)
    }

    /// E4: the reader applies only the non-empty and storable rules to a name, so a name that the edit
    /// rules refuse (a long combining sequence, a space at an end) reads back and does not refuse the
    /// session.
    @Test func aStoredNameOverTheEditRulesReadsBack() throws {
        let long = String(repeating: "e\u{301}", count: 65)
        let session = try read(
            ExportPresetTests.element(long) + ExportPresetTests.element(" Show ")
                + ExportPresetTests.element(String(repeating: "a", count: 70)))

        #expect(ExportPresetTests.names(session) == [long, " Show ", String(repeating: "a", count: 70)])
        #expect(try Session(xml: session.checkedData()) == session)
    }

    /// E4 and 0024 P3: an older version refuses the element, and a build whose newest version is the
    /// one before refuses the file as newer.
    @Test func aPresetInALowerVersionIsRefused() throws {
        #expect(throws: SessionFileError.invalidValue(element: "exportPresets", attribute: "version")) {
            try read(ExportPresetTests.element("Show"), version: driftSessionVersion)
        }
        let file = try ExportPresetTests.stored(ExportPresetTests.element("Show")).checkedData()
        #expect(throws: SessionFileError.unsupportedVersion(presetSessionVersion)) {
            try Session(xml: file, newest: driftSessionVersion)
        }
    }

    /// E4: each value outside its list refuses the file, with the attribute that holds it. These
    /// rules do not widen in a later build.
    @Test(arguments: [
        (#"format="mp3" bitRate="128" bits="24""#, "bits"), (#"format="wav" bits="24" bitRate="128""#, "bitRate"),
        (#"format="caf""#, "format"), (#"format="mp3" bitRate="128" rate="96000""#, "rate"),
        (#"format="wav" bits="32""#, "bits"), (#"format="aac" bitRate="100""#, "bitRate"),
        (#"format="flac" bits="16" channels="quad""#, "channels"),
        (#"format="flac" bits="16" loudness="loud""#, "loudness"),
        (#"format="flac" bits="16" name="""#, "name"), (#"format="flac" bits="16" name="Sh&#9;ow""#, "name"),
    ])
    func aValueOutsideItsListIsRefused(attributes: String, refused: String) {
        #expect(throws: SessionFileError.invalidValue(element: "preset", attribute: refused)) {
            try read(Self.preset(attributes))
        }
    }

    /// E4: a WAV or FLAC preset needs `bits`, an AAC or MP3 preset needs `bitRate`.
    @Test(arguments: [(#"format="wav""#, "bits"), (#"format="mp3""#, "bitRate"), (#"bits="16""#, "format")])
    func aMissingValueIsRefused(attributes: String, missing: String) {
        #expect(throws: SessionFileError.missingAttribute(element: "preset", attribute: missing)) {
            try read(Self.preset(attributes))
        }
    }

    /// `<preset>` with `attributes`, and the name, channels, and rate that `attributes` does not give.
    static func preset(_ attributes: String) -> String {
        let defaults = [#"name="Show""#, #"channels="stereo""#, #"rate="session""#].filter {
            !attributes.contains($0.prefix { $0 != "=" } + "=")
        }
        return "<preset \(defaults.joined(separator: " ")) \(attributes)/>"
    }
}
