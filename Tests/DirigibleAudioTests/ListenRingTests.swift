import CoreAudio
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// The input of one device: one sample array for each device channel, and the channel count of
/// each buffer of a call (several buffers are several streams; a count over 1 is interleaved).
struct DeviceSignal {
    let channels: [[Float]]
    let layout: [Int]

    var frames: Int { channels[0].count }

    /// Channel `c` (1-based) is a sine of `c` kHz at 48 kHz, amplitude 0.5.
    static func sines(seconds: Double, layout: [Int]) -> DeviceSignal {
        let count = layout.reduce(0, +)
        return DeviceSignal(
            channels: (1...count).map { sine(seconds: seconds, rate: 48_000, frequency: 1000 * Double($0)) },
            layout: layout)
    }
}

/// The value past the declared end of each buffer and in the spare buffer of a list.
let sentinel: Float = 9

/// Calls `body` with the buffer list of the frames `range` of `signal`, as the HAL gives it. Each
/// buffer has one more channel of sentinel samples after the bytes that it declares, and the list
/// has one spare buffer of sentinels after `mNumberBuffers` (plan G16). So a push that reads past
/// the list of its call reads the sentinel, not past an allocation.
func withPaddedList<Result>(
    _ signal: DeviceSignal, _ range: Range<Int>, _ body: (UnsafePointer<AudioBufferList>) -> Result
) -> Result {
    let list = AudioBufferList.allocate(maximumBuffers: signal.layout.count + 1)
    var data: [UnsafeMutablePointer<Float>] = []
    defer {
        for pointer in data { pointer.deallocate() }
        free(list.unsafeMutablePointer)
    }
    var channel = 0
    for (index, width) in (signal.layout + [1]).enumerated() {
        let pointer = UnsafeMutablePointer<Float>.allocate(capacity: range.count * (width + 1))
        pointer.initialize(repeating: sentinel, count: range.count * (width + 1))
        if index < signal.layout.count {
            for frame in 0..<range.count {
                for offset in 0..<width {
                    pointer[frame * width + offset] = signal.channels[channel + offset][range.lowerBound + frame]
                }
            }
            channel += width
        }
        data.append(pointer)
        list[index] = AudioBuffer(
            mNumberChannels: UInt32(width), mDataByteSize: UInt32(range.count * width * 4), mData: pointer)
    }
    list.count = signal.layout.count
    return body(list.unsafePointer)
}

/// The left and right output of each pull.
struct Played {
    var left: [Float] = []
    var right: [Float] = []

    mutating func pull(_ ring: ListenRing, frames: Int) {
        var left = [Float](repeating: -1, count: frames)
        var right = [Float](repeating: -1, count: frames)
        left.withUnsafeMutableBufferPointer { left in
            right.withUnsafeMutableBufferPointer { right in
                ring.pull(frames: frames, left: left.baseAddress!, right: right.baseAddress!)
            }
        }
        self.left += left
        self.right += right
    }
}

/// Pushes `signal` in blocks of `block` frames with one pull of `block` frames after each push.
func play(_ signal: DeviceSignal, through ring: ListenRing, block: Int = 512, into played: inout Played) {
    for start in stride(from: 0, to: signal.frames - block + 1, by: block) {
        withPaddedList(signal, start..<start + block) { ring.push($0) }
        played.pull(ring, frames: block)
    }
}

func play(_ signal: DeviceSignal, through ring: ListenRing, block: Int = 512) -> Played {
    var played = Played()
    play(signal, through: ring, block: block, into: &played)
    return played
}

/// True when `output`, from its first pull with sound, is `input` with one fixed delay, within
/// 0.01, for at least half a second.
func playsDelayed(_ output: [Float], _ input: [Float], pull: Int = 512) -> Bool {
    let starts = stride(from: 0, to: output.count, by: pull)
    guard let first = starts.first(where: { output[$0..<min($0 + pull, output.count)].contains { $0 != 0 } }) else {
        return false
    }
    return (-4096...4096).contains { shift in
        let indices = max(first, -shift)..<min(output.count, input.count - shift)
        return indices.count >= 24_000 && indices.allSatisfy { abs(output[$0] - input[$0 + shift]) <= 0.01 }
    }
}

func listenRing(_ routes: [Route.Channels], speakers: Bool = false) -> ListenRing {
    let ring = ListenRing(rate: 48_000, inputBlock: 512, pull: 512)
    ring.setMap(ChannelMap(routes: routes))
    SpeakerGuard.refresh(ring, output: { ListenOutput.offlineOutput }, watch: { _ in }, speakers: { _ in speakers })
    return ring
}

/// A1, A2, A4, and the speaker flag of the listen ring (plan slice 3).
struct ListenRingTests {
    @Test func aMonoTrackPlaysInBothChannels() {
        let ring = listenRing([.mono(1)])
        defer { ring.deallocate() }
        let signal = DeviceSignal.sines(seconds: 1, layout: [1])
        let played = play(signal, through: ring)
        let leftPlays = playsDelayed(played.left, signal.channels[0])
        #expect(leftPlays, "A1 mono: the left channel plays the input")
        let rightPlays = playsDelayed(played.right, signal.channels[0])
        #expect(rightPlays, "A1 mono: the right channel plays the input")
    }

    @Test func aStereoTrackKeepsItsSides() {
        let ring = listenRing([.stereo(1, 2)])
        defer { ring.deallocate() }
        let signal = DeviceSignal.sines(seconds: 1, layout: [2])
        let played = play(signal, through: ring)
        let leftPlays = playsDelayed(played.left, signal.channels[0])
        #expect(leftPlays, "A1 stereo: the left channel plays channel 1")
        let rightPlays = playsDelayed(played.right, signal.channels[1])
        #expect(rightPlays, "A1 stereo: the right channel plays channel 2")
    }

    /// Map channel 3 on a list of 2 channels: that track adds nothing, and the other track plays.
    @Test func aMapChannelOverTheDeviceCountIsIgnored() {
        let ring = listenRing([.mono(3), .mono(1)])
        defer { ring.deallocate() }
        let signal = DeviceSignal.sines(seconds: 1, layout: [1, 1])
        let played = play(signal, through: ring)
        let leftPlays = playsDelayed(played.left, signal.channels[0])
        #expect(leftPlays, "G16: channel 3 of a 2-channel list adds nothing")
        let rightPlays = playsDelayed(played.right, signal.channels[0])
        #expect(rightPlays, "G16: channel 3 of a 2-channel list adds nothing")
    }

    /// A list of 1 buffer of 1 channel after a map made for 2 buffers: channel 1 plays, and
    /// channel 2 is silent.
    @Test func aShortBufferListPlaysOnlyItsChannels() {
        let ring = listenRing([.stereo(1, 2)])
        defer { ring.deallocate() }
        let signal = DeviceSignal.sines(seconds: 1, layout: [1])
        let played = play(signal, through: ring)
        let leftPlays = playsDelayed(played.left, signal.channels[0])
        #expect(leftPlays, "G16: the channel of a short list plays")
        #expect(played.right.allSatisfy { $0 == 0 }, "G16: a channel that the list does not have is silent")
    }

    /// 2 buffers of 2 interleaved channels: device channel 3 is the first channel of buffer 2.
    @Test func aTwoStreamListMapsAcrossBuffers() {
        let ring = listenRing([.stereo(3, 2)])
        defer { ring.deallocate() }
        let signal = DeviceSignal.sines(seconds: 1, layout: [2, 2])
        let played = play(signal, through: ring)
        let leftPlays = playsDelayed(played.left, signal.channels[2])
        #expect(leftPlays, "two streams: channel 3 plays left")
        let rightPlays = playsDelayed(played.right, signal.channels[1])
        #expect(rightPlays, "two streams: channel 2 plays right")
    }

    /// A list of 66 channels and a map with channel 1 only: channel 65 adds nothing.
    @Test func aChannelOver64AddsNothing() {
        let ring = listenRing([.mono(1)])
        defer { ring.deallocate() }
        let tone = sine(seconds: 1, rate: 48_000)
        let signal = DeviceSignal(
            channels: [tone] + Array(repeating: [Float](repeating: 0.25, count: tone.count), count: 65), layout: [66])
        let played = play(signal, through: ring)
        let leftPlays = playsDelayed(played.left, tone)
        #expect(leftPlays, "G16: channel 65 adds nothing to channel 1")
    }

    /// A4: two rings of two devices, each with its own map and rule.
    @Test func twoRingsAreIndependent() {
        let first = listenRing([.mono(1)])
        let second = ListenRing(rate: 48_000, inputBlock: 256, pull: 256)
        defer {
            first.deallocate()
            second.deallocate()
        }
        second.setMap(ChannelMap(routes: [.mono(2)]))
        second.storeSpeakers(false, ticket: 1)
        let one = DeviceSignal.sines(seconds: 1, layout: [1])
        let two = DeviceSignal.sines(seconds: 1, layout: [2])
        var playedOne = Played()
        var playedTwo = Played()
        for start in stride(from: 0, to: 47_616, by: 512) {
            withPaddedList(one, start..<start + 512) { first.push($0) }
            playedOne.pull(first, frames: 512)
            for half in [start, start + 256] {
                withPaddedList(two, half..<half + 256) { second.push($0) }
                playedTwo.pull(second, frames: 256)
            }
        }
        let firstPlays = playsDelayed(playedOne.left, one.channels[0])
        #expect(firstPlays, "A4: the first ring plays its device")
        let secondPlays = playsDelayed(playedTwo.left, two.channels[1], pull: 256)
        #expect(secondPlays, "A4: the second ring plays its device")
    }

    /// A2 ring part: a frame waits in the ring at most the target plus one pull, with the target
    /// from the sizes (512 frames plus 2 ms at 48 kHz). The value of each input frame is its
    /// number, so each output frame says how many frames came after it before its pull.
    /// A slow test: 5.5 s alone in a debug build (run 2026-10-13-test-speed), over the 5 s of a fast test.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIRIGIBLE_SLOW_TESTS"] == "1"))
    func theRingAddsAtMostItsTarget() {
        let ring = listenRing([.mono(1)])
        defer { ring.deallocate() }
        let target = 512 + 96
        let ramp = DeviceSignal(channels: [(1...2_880_000).map(Float.init)], layout: [1])  // 60 s
        var played = Played()
        var longest = 0
        var gaps = 0
        for start in stride(from: 0, to: ramp.frames, by: 512) {
            withPaddedList(ramp, start..<start + 512) { ring.push($0) }
            played.left = []
            played.pull(ring, frames: 512)
            guard played.left[0] != 0 else { continue }
            for value in played.left {
                if value == 0 { gaps += 1 } else { longest = max(longest, start + 512 - Int(value)) }
            }
        }
        #expect(longest <= target + 512, "A2: a frame waits at most the target plus one pull (\(longest))")
        #expect(longest >= target, "A2: the ring keeps its target")
        #expect(gaps == 0, "A2: no gap after the prime")
    }

    /// The ring wraps several times, then the input stops: the render gives zeros, never old
    /// frames.
    @Test func anEmptyRingGivesZeros() {
        let ring = listenRing([.mono(1)])
        defer { ring.deallocate() }
        let signal = DeviceSignal.sines(seconds: 2, layout: [1])
        var played = play(signal, through: ring)
        let before = played.left.count
        for _ in 0..<8 { played.pull(ring, frames: 512) }
        let after = played.left[(before + 512)...]
        #expect(after.allSatisfy { $0 == 0 }, "G3: an empty ring gives zeros")
        let playedBefore = playsDelayed(Array(played.left[..<before]), signal.channels[0])
        #expect(playedBefore, "G3: the ring played before")
    }

    /// 64 pushes of 512 frames fill the ring exactly and are kept; the 65th push is dropped whole.
    @Test func aFullRingDropsThePush() {
        let ring = listenRing([.mono(1)])
        defer { ring.deallocate() }
        let ramp = DeviceSignal(channels: [(1...33_280).map(Float.init)], layout: [1])
        for start in stride(from: 0, to: 64 * 512, by: 512) {
            withPaddedList(ramp, start..<start + 512) { ring.push($0) }
        }
        #expect(ring.droppedPushes == 0, "G4: a push that fits exactly is kept")
        withPaddedList(ramp, 32_768..<33_280) { ring.push($0) }
        #expect(ring.droppedPushes == 1, "G4: a full ring drops the push")
        var played = Played()
        played.pull(ring, frames: 512)
        #expect(played.left.last == Float(32_768 - 608), "G4: the kept frames stay in order")
    }

    /// A10 core: with the speaker flag true, the render writes zeros.
    @Test func theSpeakersSilenceTheMonitor() {
        let ring = listenRing([.mono(1)])
        defer { ring.deallocate() }
        let signal = DeviceSignal.sines(seconds: 2, layout: [1])
        var played = Played()
        play(DeviceSignal(channels: [Array(signal.channels[0][..<48_128])], layout: [1]), through: ring, into: &played)
        let leftPlays = playsDelayed(played.left, signal.channels[0])
        #expect(leftPlays, "A10: the headphones play")
        ring.storeSpeakers(true, ticket: 2)
        var silent = Played()
        play(DeviceSignal(channels: [Array(signal.channels[0][48_128...])], layout: [1]), through: ring, into: &silent)
        #expect(
            silent.left.allSatisfy { $0 == 0 } && silent.right.allSatisfy { $0 == 0 }, "A10: the speakers get zeros")
    }

    /// A mute keeps the loopback flag, so a wake after the mute reports no play (code gate
    /// round 2, item 6).
    @Test func aMuteKeepsTheLoopbackFlag() {
        let ring = listenRing([.mono(1)])
        defer { ring.deallocate() }
        ring.storeSpeakers(true, loopback: true, ticket: 2)
        ring.mute()
        #expect(ring.speakers && ring.feedsItself, "the mute keeps the loopback flag")
    }

    /// While the flag is true the render still pulls, so the delay stays at the target.
    @Test func silenceKeepsTheDelay() {
        let ring = listenRing([.mono(1)])
        defer { ring.deallocate() }
        let ramp = DeviceSignal(channels: [(1...144_384).map(Float.init)], layout: [1])
        var delays: [Int] = []
        for (index, start) in stride(from: 0, to: ramp.frames, by: 512).enumerated() {
            ring.storeSpeakers((94..<188).contains(index), ticket: UInt64(index + 2))
            withPaddedList(ramp, start..<start + 512) { ring.push($0) }
            var played = Played()
            played.pull(ring, frames: 512)
            if let last = played.left.last, last != 0 { delays.append(start + 512 - Int(last)) }
        }
        #expect(delays.count >= 180, "silence: the ring plays before and after")
        #expect(Set(delays.suffix(90)) == Set(delays.prefix(90).suffix(80)), "silence: the delay stays the same")
    }

    @Test func aNewRingStartsSilent() {
        let ring = ListenRing(rate: 48_000, inputBlock: 512, pull: 512)
        defer { ring.deallocate() }
        ring.setMap(ChannelMap(routes: [.mono(1)]))
        #expect(ring.speakers, "a new ring starts with the speaker flag true")
        let played = play(DeviceSignal.sines(seconds: 1, layout: [1]), through: ring)
        #expect(played.left.allSatisfy { $0 == 0 }, "a new ring plays zeros until the first read")
    }

    /// A new map takes effect at the next push: the frames in the ring keep the old map.
    @Test func aMapChangeTakesEffectAtTheNextPush() {
        let ring = listenRing([.mono(1)])
        defer { ring.deallocate() }
        let signal = DeviceSignal(
            channels: [[Float](repeating: 0.25, count: 8192), [Float](repeating: 0.5, count: 8192)], layout: [1, 1])
        var played = Played()
        var afterChange: [Float] = []
        for start in stride(from: 0, to: 8192, by: 512) {
            if start == 4096 { ring.setMap(ChannelMap(routes: [.mono(2)])) }
            withPaddedList(signal, start..<start + 512) { ring.push($0) }
            played.pull(ring, frames: 512)
            if start == 4096 { afterChange = Array(played.left.suffix(512)) }
        }
        let values = played.left.filter { $0 != 0 }
        #expect(afterChange.allSatisfy { $0 == 0.25 }, "map change: the frames in the ring keep the old map")
        #expect(values.allSatisfy { $0 == 0.25 || $0 == 0.5 } && values.last == 0.5, "map change: the new map plays")
        #expect(values.firstIndex(of: 0.5).map { values[$0...].allSatisfy { $0 == 0.5 } } == true)
    }
}
