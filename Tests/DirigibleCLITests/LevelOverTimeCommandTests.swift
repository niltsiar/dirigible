import AVFoundation
import DirigibleCore
import Foundation
import Testing

/// `dirigible clip level-over-time` (decision 0060): the ride gain layer.
struct LevelOverTimeCommandTests {
    static let rate = 48_000

    /// Writes `Clips/f1.wav` as mono 1 kHz tone, one level in dBFS for each second; nil is silence.
    static func writeF1(_ package: TemporaryPackage, dBFS: [Double?]) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 1))
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(dBFS.count * rate)))
        buffer.frameLength = AVAudioFrameCount(dBFS.count * rate)
        for (second, level) in dBFS.enumerated() {
            let amplitude = level.map { pow(10, $0 / 20) } ?? 0
            for frame in second * rate..<(second + 1) * rate {
                buffer.floatChannelData![0][frame] = Float(
                    amplitude * sin(2 * .pi * 1_000 * Double(frame) / Double(rate)))
            }
        }
        // The file closes, and its header gets the length, at the end of this scope.
        let file = try AVAudioFile(forWriting: package.url.appending(path: "Clips/f1.wav"), settings: format.settings)
        try file.write(from: buffer)
    }

    /// `c1` and `c2` of 3 s each, one after the other, on the 6 s file `f1`: 3 s at -20 dBFS, then 3 s at
    /// -32 dBFS. The two clips make one measure group.
    static func touching() throws -> TemporaryPackage {
        let package = try package(clips: [("c1", 0, 3), ("c2", 3, 3)])
        try writeF1(package, dBFS: [-20, -20, -20, -32, -32, -32])
        return package
    }

    /// `c1` on the silent first 3 s of `f1`, `c2` on 2.5 s at the end after a gap: two measure groups.
    static func apart() throws -> TemporaryPackage {
        let package = try package(clips: [("c1", 0, 3), ("c2", 3.5, 2.5)])
        try writeF1(package, dBFS: [nil, nil, nil, -20, -20, -32])
        return package
    }

    /// Track `t1` with the clips `(id, first second, seconds)` of the 6 s file `f1`, each at the timeline
    /// second of its file second. `f1.wav` is not written.
    static func package(clips: [(String, Double, Double)]) throws -> TemporaryPackage {
        var session = Session(sampleRate: rate)
        try session.addFile(AudioFile(id: "f1", path: "f1.wav", layout: .mono, length: Frames(6 * rate)))
        try session.addTrack("t1", name: "Host", layout: .mono)
        for (id, first, seconds) in clips {
            let (start, length) = (Frames(Int(first * Double(rate))), Frames(Int(seconds * Double(rate))))
            try session.place(Clip(id: ClipID(id), file: "f1", start: start, offset: start, length: length), on: "t1")
        }
        let package = try TemporaryPackage(session)
        try FileManager.default.createDirectory(
            at: package.url.appending(path: "Clips"), withIntermediateDirectories: true)
        return package
    }

    /// The oracle of the printed numbers: the ride points inside the clip window, and the lowest and
    /// highest gain over them and the two window edges, at 0.1 dB.
    static func summary(of clip: Clip) -> (points: Int, lowest: Double, highest: Double) {
        let window = clip.offset..<(clip.offset + clip.length)
        let inside = clip.ride.points.filter { window.contains($0.frame) }
        let gains =
            inside.map(\.gain.dB) + [
                clip.ride.gain(at: clip.offset), clip.ride.gain(at: clip.offset + clip.length - 1),
            ]
        func tenth(_ value: Double) -> Double { (value * 10).rounded() / 10 + 0.0 }
        return (inside.count, tenth(gains.min()!), tenth(gains.max()!))
    }

    static func line(_ id: String, in session: Session) throws -> String {
        let clip = try #require(session.clip(ClipID(id))?.clip)
        let (points, lowest, highest) = summary(of: clip)
        return
            "\(id): leveled, \(String(format: "%.1f", lowest)) to \(String(format: "%.1f", highest)) dB, \(points) points"
    }

    /// One line for each clip with the lowest and the highest ride gain and the point count. The
    /// louder clip is cut and the quieter one is lifted. No file is written, no clip moves, and the
    /// original gain points stay.
    @Test func ridesAndPrints() async throws {
        let package = try Self.touching()
        let before = DenoiseCommandTests.clips(package)

        let result = try await package.run("clip", "level-over-time", "PKG", "c1", "c2")

        let session = try package.read()
        let lines = try ["c1", "c2"].map { try Self.line($0, in: session) }
        #expect(
            result == CLIResult(status: 0, stdout: lines.joined(separator: "\n") + "\n", stderr: ""),
            "level-over-time: \(result)")
        let (c1, c2) = (try #require(session.clip("c1")?.clip), try #require(session.clip("c2")?.clip))
        let (loud, quiet) = (Self.summary(of: c1), Self.summary(of: c2))
        #expect(loud.lowest < 0 && quiet.highest > 0 && quiet.highest > loud.highest, "\(lines)")
        #expect(c1.ride == c2.ride && c1.file == "f1" && c1.envelope.isEmpty, "one list; the clips stay on f1")
        #expect(DenoiseCommandTests.clips(package) == before, "a ride writes no audio file")
    }

    /// A clip on silence prints "no measurement" and has no ride; the other group is leveled. A
    /// run with no measurement writes nothing.
    @Test func unmeasuredClipPrints() async throws {
        let mixed = try Self.apart()

        let result = try await mixed.run("clip", "level-over-time", "PKG", "c1", "c2")

        let session = try mixed.read()
        let text = "c1: no measurement\n\(try Self.line("c2", in: session))\n"
        #expect(result == CLIResult(status: 0, stdout: text, stderr: ""), "mixed: \(result)")
        #expect(session.clip("c1")?.clip.ride.isEmpty == true && session.clip("c2")?.clip.ride.isEmpty == false)

        let silent = try Self.touching()
        try Self.writeF1(silent, dBFS: [Double?](repeating: nil, count: 6))
        let before = try silent.xml()

        let none = try await silent.run("clip", "level-over-time", "PKG", "c1")

        #expect(none == CLIResult(status: 0, stdout: "c1: no measurement\n", stderr: ""), "silent: \(none)")
        #expect(try silent.xml() == before, "a run with no measurement wrote")
    }

    /// An unknown clip exits 1 with the text of the session and changes nothing.
    @Test func unknownClipExits1() async throws {
        let package = try Self.touching()
        let before = try package.xml()

        let result = try await package.run("clip", "level-over-time", "PKG", "c1", "zz")

        #expect(result.status == 1 && result.stdout == "", "unknown clip: \(result)")
        #expect(result.stderr.hasPrefix("Error: ") && result.stderr.contains("zz"), "\(result.stderr)")
        #expect(try package.xml() == before)
    }

    /// A source that does not read exits 1 with the read error text and changes nothing.
    @Test func unreadableExits1() async throws {
        let package = try Self.touching()
        try FileManager.default.removeItem(at: package.url.appending(path: "Clips/f1.wav"))
        let before = try package.xml()

        let result = try await package.run("clip", "level-over-time", "PKG", "c1")

        #expect(
            result == CLIResult(status: 1, stdout: "", stderr: "Error: file f1 is missing; no ride changed.\n"),
            "\(result)")
        #expect(try package.xml() == before)
    }

    /// Control-C after the measure leaves `session.xml` as it was and exits 130 with nothing on
    /// stdout. The child holds after the measure and says so on stderr (`DIRIGIBLE_RIDE_HOLD`), so the
    /// signal comes before the save at any load.
    @Test func interruptWritesNothing() async throws {
        let package = try Self.touching()
        let before = (try package.xml(), DenoiseCommandTests.clips(package))
        let (stdout, stderr) = (package.folder.appending(path: "stdout"), package.folder.appending(path: "stderr"))
        let pid = try spawnDirigible(
            "clip", "level-over-time", package.path, "c1", "c2", environment: ["DIRIGIBLE_RIDE_HOLD": "1"],
            output: (stdout, stderr))
        var status: Int32 = 0
        defer {
            if waitpid(pid, &status, WNOHANG) == 0 {
                kill(pid, SIGKILL)
                waitpid(pid, &status, 0)
            }
        }
        let end = ContinuousClock.now + .seconds(60)
        while (try? String(contentsOf: stderr, encoding: .utf8)) != "hold\n", ContinuousClock.now < end {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(try String(contentsOf: stderr, encoding: .utf8) == "hold\n", "the command did not hold in 60 s")

        kill(pid, SIGINT)
        let stop = ContinuousClock.now + .seconds(60)
        var finished = waitpid(pid, &status, WNOHANG)
        while finished == 0, ContinuousClock.now < stop {
            try await Task.sleep(for: .milliseconds(1))
            finished = waitpid(pid, &status, WNOHANG)
        }

        try #require(finished == pid, "the command did not end in 60 s")
        #expect(status >> 8 == 128 + SIGINT && status & 0x7f == 0, "wait status \(status)")
        #expect(try String(contentsOf: stdout, encoding: .utf8) == "", "an interrupted ride printed")
        #expect(try package.xml() == before.0, "an interrupted ride changed session.xml")
        #expect(DenoiseCommandTests.clips(package) == before.1)
    }

    // MARK: Remove

    /// A 60 s file `f1`; the ride lists need no audio, and `--clear` reads none. The old ride is the
    /// line through a point each 5 s with 1 dB more each time.
    static func old() throws -> GainEnvelope {
        try #require(
            GainEnvelope(
                (0...12).map { GainEnvelope.Point(frame: Frames($0 * 5 * rate), gain: Gain(dB: Double($0) - 6)!) }))
    }

    /// The clips `(id, track, start second, offset second, seconds)` with the ride `old()`, also the
    /// clips of `bare` have none.
    static func ridden(_ clips: [(String, String, Int, Int, Int)], bare: Set<String> = []) throws -> TemporaryPackage {
        var session = Session(sampleRate: rate)
        try session.addFile(AudioFile(id: "f1", path: "f1.wav", layout: .mono, length: Frames(60 * rate)))
        for track in Set(clips.map(\.1)).sorted() { try session.addTrack(TrackID(track), name: track, layout: .mono) }
        let ride = try old()
        for (id, track, start, offset, seconds) in clips {
            try session.place(
                Clip(
                    id: ClipID(id), file: "f1", start: Frames(start * rate), offset: Frames(offset * rate),
                    length: Frames(seconds * rate), ride: bare.contains(id) ? .empty : ride), on: TrackID(track))
        }
        return try TemporaryPackage(session)
    }

    /// `--clear` empties the ride of each named clip, reads no audio, and prints "ride removed", or
    /// "no ride" for a clip with none.
    @Test func clearPrints() async throws {
        let package = try Self.ridden([("c1", "t1", 0, 0, 30), ("c2", "t1", 30, 30, 30)], bare: ["c2"])

        let result = try await package.run("clip", "level-over-time", "PKG", "c1", "c2", "--clear")

        #expect(
            result == CLIResult(status: 0, stdout: "c1: ride removed\nc2: no ride\n", stderr: ""), "clear: \(result)")
        let session = try package.read()
        #expect(session.clip("c1")?.clip.ride.isEmpty == true, "the ride stays on c1")
    }

    /// `--clear --from --to` on a range past a ridden clip prints "no ride in the range" and keeps the ride.
    @Test func clearOnARangePastARiddenClipPrints() async throws {
        let package = try Self.ridden([("c1", "t1", 0, 0, 30)])

        let result = try await package.run(
            "clip", "level-over-time", "PKG", "c1", "--clear", "--from", "\(40 * Self.rate)", "--to",
            "\(50 * Self.rate)")

        #expect(result == CLIResult(status: 0, stdout: "c1: no ride in the range\n", stderr: ""), "\(result)")
        #expect(try package.read().clip("c1")?.clip.ride == (try Self.old()))
    }

    /// `--clear --from --to` makes the ride 0 dB on the range and keeps the old ride outside the
    /// range and its 500 ms ramps.
    @Test func clearOnARangePrints() async throws {
        let package = try Self.ridden([("c1", "t1", 0, 0, 60)])
        let old = try Self.old()

        let result = try await package.run(
            "clip", "level-over-time", "PKG", "c1", "--clear", "--from", "\(20 * Self.rate)", "--to",
            "\(30 * Self.rate)")

        #expect(result == CLIResult(status: 0, stdout: "c1: ride removed\n", stderr: ""), "\(result)")
        let ride = try #require(try package.read().clip("c1")?.clip.ride)
        for frame in stride(from: 20 * Self.rate, to: 30 * Self.rate, by: 997) {
            #expect(abs(ride.gain(at: Frames(frame))) < 1e-9, "frame \(frame): \(ride.gain(at: Frames(frame))) dB")
        }
        let before = Array(stride(from: 0, to: 19 * Self.rate, by: 4_001))
        let after = Array(stride(from: 31 * Self.rate, to: 60 * Self.rate, by: 4_001))
        for frame in before + after {
            #expect(abs(ride.gain(at: Frames(frame)) - old.gain(at: Frames(frame))) < 1e-9, "frame \(frame)")
        }
    }

    /// A clip that plays a changed file frame and is not named keeps its list
    /// exactly: part B of an unmoved split.
    @Test func clearOnARangeKeepsAnUnnamedClip() async throws {
        let package = try Self.ridden([("c1", "t1", 0, 0, 30), ("c2", "t1", 30, 30, 30)])
        let old = try Self.old()

        let result = try await package.run(
            "clip", "level-over-time", "PKG", "c1", "--clear", "--from", "\(29 * Self.rate)", "--to",
            "\(31 * Self.rate)")

        #expect(result == CLIResult(status: 0, stdout: "c1: ride removed\n", stderr: ""), "\(result)")
        let session = try package.read()
        #expect(session.clip("c2")?.clip.ride == old, "the unnamed clip changed its ride")
        #expect(session.clip("c1")?.clip.ride != old)
    }

    /// A clip with the same list that plays no file frame of the changed range is
    /// not named, gets the new list, and hears the same gain.
    @Test func clearOnARangeGivesTheNewListToAClipWithNoChangedFrame() async throws {
        let package = try Self.ridden([("c1", "t1", 0, 0, 30), ("c3", "t2", 100, 40, 20)])
        let old = try Self.old()

        let result = try await package.run(
            "clip", "level-over-time", "PKG", "c1", "--clear", "--from", "\(29 * Self.rate)", "--to",
            "\(31 * Self.rate)")

        #expect(result == CLIResult(status: 0, stdout: "c1: ride removed\n", stderr: ""), "\(result)")
        let session = try package.read()
        let (c1, c3) = (try #require(session.clip("c1")?.clip), try #require(session.clip("c3")?.clip))
        #expect(c3.ride == c1.ride && c3.ride != old, "the third clip got another list")
        for frame in stride(from: 40 * Self.rate, to: 60 * Self.rate, by: 4_001) {
            #expect(abs(c3.ride.gain(at: Frames(frame)) - old.gain(at: Frames(frame))) < 1e-9, "frame \(frame)")
        }
    }

    /// `--from` with no `--clear` exits 64 and changes nothing.
    @Test func fromWithoutClearExits64() async throws {
        let package = try Self.ridden([("c1", "t1", 0, 0, 30)])
        let before = try package.xml()

        let result = try await package.run("clip", "level-over-time", "PKG", "c1", "--from", "0", "--to", "48000")

        #expect(result.status == 64 && result.stderr.contains("from and to need clear."), "\(result)")
        #expect(try package.xml() == before)
    }
}
