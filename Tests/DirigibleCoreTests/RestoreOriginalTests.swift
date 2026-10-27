import Testing

@testable import DirigibleCore

/// The gains of Restore Original (decision 0057 D6, criteria C2 and C6). At 48 kHz the handle on
/// each side of a clip is 10 s, 480 000 frames, so the render of "A" starts at frame 520 000 of "f".
struct RestoreOriginalTests {
    let noise = Treatment(.noise(.standard))

    /// The mono file "f" and the clip "A" (offset 1 000 000, length 100 000) with `gain` dB and
    /// `envelope`, rendered into "f NR" with an added gain of 1 dB.
    func rendered(gain: Double, envelope: GainEnvelope = .empty) throws -> Session {
        var session = Session(sampleRate: 48_000)
        try session.addTrack("t", name: "Host", layout: .mono)
        try session.addFile(AudioFile(id: "f", path: "f.wav", layout: .mono, length: 10_000_000))
        try session.place(
            Clip(
                id: "A", file: "f", start: 0, offset: 1_000_000, length: 100_000, gain: try #require(Gain(dB: gain)),
                envelope: envelope), on: "t")
        let runs = try session.clipRuns(of: ["A"]).map {
            RenderedRun(run: $0, stem: "f NR", treatment: noise, addedGain: try #require(Gain(dB: 1)))
        }
        _ = try session.repoint(runs)
        return session
    }

    /// C2 limit. +95.5 dB plus the added 1 dB clamps at 96 dB, so the restore gives 95 dB. +10 dB
    /// gives +10 dB back.
    @Test func gainNearTheTopClamps() throws {
        var top = try rendered(gain: 95.5)
        var plain = try rendered(gain: 10)
        #expect(top.clip("A")?.clip.gain == Gain(dB: 96) && plain.clip("A")?.clip.gain == Gain(dB: 11))

        try top.restoreOriginals(["A"])
        try plain.restoreOriginals(["A"])

        #expect(top.clip("A")?.clip.gain == Gain(dB: 95))
        #expect(plain.clip("A")?.clip.gain == Gain(dB: 10))
    }

    /// C2. The envelope moves with the file: the render and the restore keep the gain of each clip
    /// frame, and the restore gives the envelope of the user back.
    @Test func restoreKeepsTheEnvelopeGain() throws {
        let points = try [(1_010_000, 3.0), (1_090_000, -6.0)].map {
            GainEnvelope.Point(frame: Frames($0.0), gain: try #require(Gain(dB: $0.1)))
        }
        let envelope = try #require(GainEnvelope(points))
        var session = try rendered(gain: 0, envelope: envelope)
        let moved = try #require(session.clip("A")?.clip)
        #expect(moved.file == "f NR" && moved.envelope.points.map(\.frame) == [490_000, 570_000])
        #expect(moved.envelope.gain(at: 530_000) == envelope.gain(at: 1_050_000))

        try session.restoreOriginals(["A"])

        let restored = try #require(session.clip("A")?.clip)
        #expect(restored.file == "f" && restored.offset == 1_000_000 && restored.envelope == envelope)
    }
}
