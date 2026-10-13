import AVFoundation
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// Vari-speed criteria V1, V2, V3, V7, and V13 (run 2026-10-13-preroll-varispeed): the Player plays
/// a 1x play at a speed with the pitch kept, on the real graph in offline manual rendering.
struct PlayerSpeedTests {
    let forward = Shuttle(direction: .forward, rate: .one)
    let rate = 48_000

    /// A mono session with one clip of a 440 Hz sine of 4 s (amplitude 0.5) at timeline 0.
    func sinePackage() throws -> MixPackage {
        let package = try MixPackage()
        let tone = sine(seconds: 4, rate: Double(rate), frequency: 440)
        try package.addFile("f1", channels: [tone])
        try package.addTrack("t1", clip: "c1", file: "f1", start: 0, offset: 0, length: Frames(tone.count))
        return package
    }

    func player(_ package: MixPackage, unit: @escaping SpeedUnitLookup = findSpeedUnit, latency: Int = 0) -> Player {
        let url = package.url
        return Player(
            package: { url }, output: .offline, session: package.session, speedUnit: unit, offlineLatency: latency)
    }

    /// The frequency in `range` from the rising zero crossings, with a linear interpolation.
    func frequency(_ x: [Float], _ range: Range<Int>) -> Double {
        var (first, last, count) = (-1.0, -1.0, 0)
        for i in range.dropFirst() where x[i - 1] < 0 && x[i] >= 0 {
            let crossing = Double(i - 1) + Double(-x[i - 1] / (x[i] - x[i - 1]))
            if first < 0 { first = crossing }
            last = crossing
            count += 1
        }
        return count > 1 ? Double(count - 1) * Double(rate) / (last - first) : 0
    }

    /// V1: 440 Hz within 1% (a tape speed of 1.5 gives 660 Hz), and the length 4 s / speed within 0.1 s.
    @Test(arguments: [Speed.x075, .x125, .x150, .x175, .x200])
    func keepsThePitch(speed: Speed) async throws {
        let package = try sinePackage()
        let player = player(package)
        await player.apply(.play(from: 0, shuttle: forward, speed: speed), number: 1)
        let heard = 4 / speed.factor
        let out = await player.renderOffline(frames: Int((heard + 0.5) * Double(rate)))[0]
        let middle = Int(heard / 2 * Double(rate))
        let hertz = frequency(out, middle - rate / 2..<middle + rate / 2)
        #expect(abs(hertz - 440) <= 4.4, "\(speed): \(hertz) Hz, not 440 Hz")
        let end = Double(out.lastIndex { abs($0) > 0.05 } ?? 0) / Double(rate)
        #expect(abs(end - heard) <= 0.1, "\(speed): the tone ends at \(end) s, not \(heard) s")
    }

    /// V2: at speed 1 the node feeds the main mixer, and the output is the mix. The play at 1.5
    /// before it puts the unit in the graph, so the 1x play must take it out again.
    @Test func oneIsTheDirectPath() async throws {
        let package = try sinePackage()
        let player = player(package)
        await player.apply(.play(from: 0, shuttle: forward, speed: .x150), number: 1)
        _ = await player.renderOffline(frames: 4_800)
        #expect(await player.speedUnitInGraph, "a play at 1.5 has the unit")
        await player.apply(.play(from: 2_400, shuttle: forward, speed: .one), number: 2)
        #expect(await !player.speedUnitInGraph, "a play at 1 has no unit")
        let out = await player.renderOffline(frames: 9_600)
        let mix = try package.mix(2_400..<12_000)
        #expect(maxError(out[0], mix[0]) <= 1e-6 && maxError(out[1], mix[1]) <= 1e-6, "the 1x output is the mix")
    }

    /// V3: after n output frames at speed s the position is the anchor + n x s within one chunk x s,
    /// forward and reverse. The first refill schedules `Player.depth` chunks of output time.
    @Test(arguments: [Shuttle.Direction.forward, .reverse])
    func positionFollowsTheSpeed(direction: Shuttle.Direction) async throws {
        let package = try sinePackage()
        let player = player(package)
        let start = direction == .forward ? 24_000 : 168_000
        let shuttle = Shuttle(direction: direction, rate: .one)
        await player.apply(.play(from: Frames(start), shuttle: shuttle, speed: .x200), number: 1)
        let chunk = rate / 10
        let ahead = await player.scheduledFrames
        let depth = Player.depth * chunk * 2
        #expect(ahead >= depth, "\(ahead) node frames ahead at 2x, not \(Player.depth) chunks of output")
        _ = await player.renderOffline(frames: rate / 2)
        let expected = start + (direction == .forward ? rate : -rate)
        let frame = await player.reading().frame.count
        #expect(abs(frame - expected) <= chunk * 2, "\(direction): position \(frame), not \(expected)")
    }

    /// V3: the heard node frames are the node frames less the output latency x the speed, once.
    @Test func heardFrame() {
        #expect(Player.heard(nodeFrames: 10_000, latency: 480, speed: 1.5) == 9_280)
        #expect(Player.heard(nodeFrames: 10_000, latency: 480, speed: 1) == 9_520)
        #expect(Player.heard(nodeFrames: 300, latency: 480, speed: 2) == 0)
    }

    /// Code gate 1 item 3: a change from 0.75x to 2x during a play on a 200 ms output keeps the
    /// heard frame: the output frames from before the change hold 0.75x until they played.
    @Test func aStepKeepsTheHeardFrame() {
        let (latency, node) = (9_600, 100_000)
        let held = Player.held(nodeFrames: node, latency: latency, speed: 0.75, step: nil)
        let step = Player.SpeedStep(node: node, held: held)
        let heard = [0, 9_600, 19_200, 30_000].map {
            Player.heard(nodeFrames: node + $0, latency: latency, speed: 2, step: step)
        }
        #expect(heard == [92_800, 96_400, 100_000, 110_800], "the heard frames after the change: \(heard)")
    }

    /// V7: a 1x forward play at a speed other than 1 gives no meter value; the same play at 1 does.
    @Test func meterSkipsOtherSpeeds() async throws {
        let (player, package) = try loudnessPlayer([(10, -20)])
        await player.apply(.play(from: 0, shuttle: forward, speed: .x150), number: 1)
        for _ in 0..<30 {
            _ = await player.renderOffline(frames: 4_800)
            let values = await player.reading().loudness
            #expect(values.momentary == nil && values.integrated == nil, "a play at 1.5 fed the meter: \(values)")
        }
        await player.apply(.play(from: 0, shuttle: forward, speed: .one), number: 2)
        for _ in 0..<30 { _ = await player.renderOffline(frames: 4_800) }
        #expect(await player.reading().loudness.momentary != nil, "a play at 1 feeds the meter")
        _ = package
    }

    /// V13: with no unit, a play at 1.5 plays the mix at 1x.
    @Test func unitLoadFailurePlaysAtOne() async throws {
        let package = try sinePackage()
        let player = player(package, unit: { nil })
        await player.apply(.play(from: 2_400, shuttle: forward, speed: .x150), number: 1)
        let out = await player.renderOffline(frames: 9_600)
        let mix = try package.mix(2_400..<12_000)
        #expect(maxError(out[0], mix[0]) <= 1e-6, "the output is the mix at 1x")
        #expect(await player.reading().frame == 12_000)
        #expect(await !player.speedUnitInGraph)
    }

    /// The power of `frequency` in `x` (one Goertzel bin), for the energy of one tone.
    func power(_ x: [Float], _ frequency: Double) -> Double {
        let w = 2 * Double.pi * frequency / Double(rate)
        var (re, im) = (0.0, 0.0)
        for (i, value) in x.enumerated() {
            re += Double(value) * cos(w * Double(i))
            im -= Double(value) * sin(w * Double(i))
        }
        return (re * re + im * im) / Double(x.count * x.count)
    }

    /// Code gate 1 item 1: a new play clears the unit. The file has 440 Hz for 2 s, then 880 Hz.
    /// After a seek past 2 s during a 1.5x play, and after 1.5x, 1x, 1.5x, the first 0.1 s of
    /// output has no 440 Hz from the old position.
    @Test func aNewPlayClearsTheUnit() async throws {
        let package = try MixPackage()
        let tones =
            sine(seconds: 2, rate: Double(rate), frequency: 440) + sine(seconds: 2, rate: Double(rate), frequency: 880)
        try package.addFile("f1", channels: [tones])
        try package.addTrack("t1", clip: "c1", file: "f1", start: 0, offset: 0, length: Frames(tones.count))
        let player = player(package)
        let after: Frames = 144_000
        for (number, between) in [(1, nil), (31, Speed.one)] {
            await player.apply(.play(from: 0, shuttle: forward, speed: .x150), number: number)
            _ = await player.renderOffline(frames: rate / 2)
            if let between {
                await player.apply(.play(from: after, shuttle: forward, speed: between), number: number + 10)
                _ = await player.renderOffline(frames: rate / 10)
            }
            await player.apply(.play(from: after, shuttle: forward, speed: .x150), number: number + 20)
            let out = await player.renderOffline(frames: rate / 10)[0]
            let (old, new) = (power(out, 440), power(out, 880))
            #expect(old < new / 100, "\(between.map { "via \($0)" } ?? "seek"): 440 Hz at \(old), 880 Hz at \(new)")
        }
    }

    /// Code gate 2 item 1: on an output with 200 ms of latency, a change from 0.75x to 2x during
    /// the play does not move the heard frame back, at the change or after it.
    @Test func aChangeOnALateOutputKeepsTheHeardFrame() async throws {
        let package = try sinePackage()
        let player = player(package, latency: 9_600)
        await player.apply(.play(from: 0, shuttle: forward, speed: .x075), number: 1)
        _ = await player.renderOffline(frames: rate)
        var last = await player.reading().frame.count
        #expect(await player.setSpeed(.x200))
        for _ in 0..<6 {
            let frame = await player.reading().frame.count
            #expect(frame >= last, "the heard frame went back from \(last) to \(frame)")
            last = frame
            _ = await player.renderOffline(frames: rate / 20)
        }
    }

    /// Code gate 2 item 2: when the unit refuses the rate during a play, the change returns false
    /// and does not rewire the playing node, so the play goes on through the unit.
    @Test func aRefusedRateDuringPlayKeepsTheGraph() async throws {
        let package = try sinePackage()
        let player = player(package)
        await player.apply(.play(from: 0, shuttle: forward, speed: .x150), number: 1)
        _ = await player.renderOffline(frames: rate / 2)
        await player.refuseRates()
        #expect(await !player.setSpeed(.x200), "a refused rate is not a change")
        #expect(await player.speedUnitInGraph, "the change rewired the playing node")
    }

    /// Code gate 1 item 8: a play whose rate the unit refuses plays the mix at 1x, with no unit.
    @Test func aRefusedRatePlaysAtOne() async throws {
        let package = try sinePackage()
        let player = player(package)
        await player.refuseRates()
        await player.apply(.play(from: 2_400, shuttle: forward, speed: .x150), number: 1)
        let out = await player.renderOffline(frames: 9_600)
        let mix = try package.mix(2_400..<12_000)
        #expect(maxError(out[0], mix[0]) <= 1e-6, "the output is the mix at 1x")
        #expect(await !player.speedUnitInGraph)
    }

    @Test func fasterAndSlowerStopAtTheLimits() {
        #expect(Speed.one.faster == .x125 && Speed.x175.faster == .x200 && Speed.x200.faster == .x200)
        #expect(Speed.one.slower == .x075 && Speed.x125.slower == .one && Speed.x075.slower == .x075)
        #expect(Speed.allCases.map(\.factor) == [0.75, 1, 1.25, 1.5, 1.75, 2])
    }
}
