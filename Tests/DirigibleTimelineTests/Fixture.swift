import DirigibleCore

@testable import DirigibleTimeline

/// The small fixture of the mouse-edits run: tracks t1 and t2 (mono) and t3 (stereo) at 48 kHz,
/// 480 frames per point, 60 pt lanes. On t1, clip A (file fa, 144,000 frames) at 48,000 ..< 96,000
/// with offset 0 (x 100 to 200 pt), and clip B (file fb, 144,000 frames) at 144,000 ..< 192,000
/// with offset 48,000 (x 300 to 400 pt). On t2, clip C (file fa) at 48,000 ..< 96,000.
enum Fixture {
    static let geometry = LaneGeometry(scale: TimelineScale(framesPerPoint: 480), laneHeight: 60)!
    static let a = Clip(id: "A", file: "fa", start: 48_000, offset: 0, length: 48_000)
    static let b = Clip(id: "B", file: "fb", start: 144_000, offset: 48_000, length: 48_000)
    static let c = Clip(id: "C", file: "fa", start: 48_000, offset: 0, length: 48_000)

    static func session(withB: Bool = true) throws -> Session {
        var session = Session(sampleRate: 48_000)
        try session.addFile(AudioFile(id: "fa", path: "fa.wav", layout: .mono, length: 144_000))
        try session.addFile(AudioFile(id: "fb", path: "fb.wav", layout: .mono, length: 144_000))
        try session.addTrack("t1", name: "T1", layout: .mono)
        try session.addTrack("t2", name: "T2", layout: .mono)
        try session.addTrack("t3", name: "T3", layout: .stereo)
        try session.place(a, on: "t1")
        if withB { try session.place(b, on: "t1") }
        try session.place(c, on: "t2")
        return session
    }
}

/// Test shims of decision 0038: the range tests write a range selection as Marks.
extension GestureEffect {
    static func marks(_ marks: Marks) -> GestureEffect { .selection(.range(marks)) }
    /// A click on a clip selects it as a set of one clip (decision 0038).
    static func clip(_ id: ClipID) -> GestureEffect { .selection(.clips(ClipSet(id))) }
}

extension ClipInspection {
    init?(marks: Marks, session: Session) { self.init(selection: .range(marks), session: session) }
}
