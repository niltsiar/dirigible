import Atomics
import AudioToolbox
import CoreAudio
import os

/// The stereo frame ring of one listened device (decision 0044). The input IOProc of the device
/// pushes, and the render of its output unit pulls. It holds pointers and `UnsafeAtomic` values
/// only, as `CaptureRing`, so a copy is the same ring and nothing in it uses ARC.
///
/// `head` and `tail` are monotonic frame counts. The push loads `tail` acquiring and stores `head`
/// releasing. The pull loads `head` acquiring and stores `tail` releasing.
struct ListenRing: @unchecked Sendable {
    /// Frames per side: 0.68 s at 48 kHz.
    static let capacity = 1 << 15

    private struct Storage {
        let left: UnsafeMutablePointer<Float>
        let right: UnsafeMutablePointer<Float>
        let head: UnsafeAtomic<Int>
        let tail: UnsafeAtomic<Int>
        let leftMask: UnsafeAtomic<UInt64>
        let rightMask: UnsafeAtomic<UInt64>
        /// The frame count of the last push. The render reads it to grow its rule.
        let lastPush: UnsafeAtomic<Int>
        /// The pushes that found no room.
        let dropped: UnsafeAtomic<Int>
        /// The speaker flag in bit 0, the loopback flag in bit 1, and the ticket of their store
        /// above them.
        let speakers: UnsafeAtomic<UInt64>
        /// The last ticket that a refresh took (fetch-and-add).
        let tickets: UnsafeAtomic<UInt64>
        /// The control state of the speaker guard. A pointer, so a copy of the storage on an IO
        /// thread does no retain. No IO callback takes the lock.
        let watchState: UnsafeMutablePointer<OSAllocatedUnfairLock<WatchState>>
        /// The loopback devices of the listened input. An output that contains one feeds the
        /// monitor into its own input.
        let loopback: Loopback
        /// Called after each refresh of the speaker guard, on the thread of the refresh.
        let wake: @Sendable () -> Void
        /// Only the render reads or writes it.
        var rule: DriftRule
    }

    private let storage: UnsafeMutablePointer<Storage>

    /// Writes zeros to every frame, so the IO threads never touch a new page first. The speaker
    /// flag starts true: the render plays zeros until the first read of the default output.
    init(
        rate: Double, inputBlock: Int, pull: Int, loopback: Loopback = .devices([]),
        wake: @escaping @Sendable () -> Void = {}
    ) {
        let left = UnsafeMutablePointer<Float>.allocate(capacity: Self.capacity)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: Self.capacity)
        left.initialize(repeating: 0, count: Self.capacity)
        right.initialize(repeating: 0, count: Self.capacity)
        let watchState = UnsafeMutablePointer<OSAllocatedUnfairLock<WatchState>>.allocate(capacity: 1)
        watchState.initialize(to: OSAllocatedUnfairLock(initialState: WatchState()))
        storage = .allocate(capacity: 1)
        storage.initialize(
            to: Storage(
                left: left, right: right, head: .create(0), tail: .create(0), leftMask: .create(0),
                rightMask: .create(0), lastPush: .create(0), dropped: .create(0), speakers: .create(1),
                tickets: .create(0), watchState: watchState, loopback: loopback, wake: wake,
                rule: DriftRule(inputBlock: inputBlock, pull: pull, rate: rate)))
    }

    /// Frees the frames after a clean detach and a clean unit stop: no IO call can come.
    func deallocateBytes() {
        storage.pointee.left.deallocate()
        storage.pointee.right.deallocate()
    }

    /// Frees the frames and the atomics. Only for a ring that no IO call or listener reached.
    func deallocate() {
        deallocateBytes()
        let ring = storage.pointee
        for atomic in [ring.head, ring.tail, ring.lastPush, ring.dropped] { atomic.destroy() }
        for atomic in [ring.leftMask, ring.rightMask, ring.speakers, ring.tickets] { atomic.destroy() }
        ring.watchState.deinitialize(count: 1)
        ring.watchState.deallocate()
        storage.deinitialize(count: 1)
        storage.deallocate()
    }

    /// The client data of the IOProc, the render, and the speaker listeners.
    var context: UnsafeMutableRawPointer { UnsafeMutableRawPointer(storage) }

    /// The ring of a client data pointer.
    init(context: UnsafeMutableRawPointer) { storage = context.assumingMemoryBound(to: Storage.self) }

    /// The next push uses `map`. The frames in the ring keep the map of their push.
    func setMap(_ map: ChannelMap) {
        storage.pointee.leftMask.store(map.left, ordering: .relaxed)
        storage.pointee.rightMask.store(map.right, ordering: .relaxed)
    }

    var droppedPushes: Int { storage.pointee.dropped.load(ordering: .relaxed) }

    /// The frames in the ring. For tests.
    var available: Int {
        storage.pointee.head.load(ordering: .acquiring) - storage.pointee.tail.load(ordering: .relaxed)
    }

    /// Empties the ring and makes a new drift rule. Call it only while no render runs: before
    /// the first unit start, or after a clean unit stop (probe P9: no render after the stop
    /// returns). The IOProc can still push.
    func prepare(rate: Double, inputBlock: Int, pull: Int) {
        storage.pointee.rule = DriftRule(inputBlock: inputBlock, pull: pull, rate: rate)
        storage.pointee.tail.store(storage.pointee.head.load(ordering: .acquiring), ordering: .releasing)
    }

    /// Zeros for good: a ticket that no refresh reaches.
    func mute() { storeSpeakers(true, ticket: UInt64.max >> 2) }

    /// True while the render must play zeros: the default output is the built-in speakers.
    var speakers: Bool { storage.pointee.speakers.load(ordering: .relaxed) & 1 == 1 }

    /// True when the last refresh found a loopback device of the input in the output.
    var feedsItself: Bool { storage.pointee.speakers.load(ordering: .relaxed) & 2 == 2 }

    /// A new ticket, larger than each ticket before it, also on another thread.
    func nextTicket() -> UInt64 { storage.pointee.tickets.wrappingIncrementThenLoad(ordering: .relaxed) }

    /// Stores the flags only when no newer ticket stored first.
    func storeSpeakers(_ speakers: Bool, loopback: Bool = false, ticket: UInt64) {
        let word = ticket << 2 | (loopback ? 2 : 0) | (speakers ? 1 : 0)
        var stored = storage.pointee.speakers.load(ordering: .relaxed)
        while stored >> 2 < ticket {
            let (exchanged, original) = storage.pointee.speakers.compareExchange(
                expected: stored, desired: word, ordering: .relaxed)
            if exchanged { return }
            stored = original
        }
    }

    var watchState: OSAllocatedUnfairLock<WatchState> { storage.pointee.watchState.pointee }

    var loopback: Loopback { storage.pointee.loopback }

    /// Tells the owner that a refresh stored the flags.
    func woke() { storage.pointee.wake() }

    /// The IOProc side.
    func push(_ input: UnsafePointer<AudioBufferList>) { Self.push(storage, input) }

    /// The listen IOProc (decision 0013 Callbacks): its client data is the ring context.
    static let ioProc: AudioDeviceIOProc = { _, _, input, _, _, _, context in
        guard let context else { return noErr }
        push(context.assumingMemoryBound(to: Storage.self), input)
        return noErr
    }

    /// The render of the output unit: 2 non-interleaved Float32 channels at the input rate.
    static let render: AURenderCallback = { context, _, _, _, frames, data in
        guard let data, data.pointee.mNumberBuffers >= 2 else { return noErr }
        let buffers = UnsafeMutableAudioBufferListPointer(data)
        guard let left = buffers[0].mData, let right = buffers[1].mData else { return noErr }
        pull(
            context.assumingMemoryBound(to: Storage.self), frames: Int(frames),
            left: left.assumingMemoryBound(to: Float.self), right: right.assumingMemoryBound(to: Float.self))
        return noErr
    }

    /// The render side: `frames` frames into `left` and `right`.
    func pull(frames: Int, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        Self.pull(storage, frames: frames, left: left, right: right)
    }

    // MARK: Real-time path: pointer math, memcpy, adds, and atomic loads and stores only.

    /// Adds each channel of the list of this call to the left or the right sum when the map has
    /// its device channel number. It reads no channel by a map index, so a map channel that the
    /// list does not have adds nothing. A device channel over 64 adds nothing. A full ring drops
    /// the whole push.
    private static func push(_ storage: UnsafeMutablePointer<Storage>, _ input: UnsafePointer<AudioBufferList>) {
        let count = Int(input.pointee.mNumberBuffers)
        // The buffers start one AudioBuffer before the end of the list type, as in
        // UnsafeMutableAudioBufferListPointer, but with no bounds check: the count is the HAL's.
        let buffers = UnsafeRawPointer(input + 1).assumingMemoryBound(to: AudioBuffer.self) - 1
        var frames = Int.max
        for index in 0..<count where buffers[index].mData != nil && buffers[index].mNumberChannels > 0 {
            frames = min(frames, Int(buffers[index].mDataByteSize) / (4 * Int(buffers[index].mNumberChannels)))
        }
        guard frames != .max, frames > 0 else { return }
        // One field at a time: a copy of `storage.pointee` reads `rule`, which the render writes.
        storage.pointee.lastPush.store(frames, ordering: .relaxed)
        let head = storage.pointee.head.load(ordering: .relaxed)
        guard frames <= capacity - (head - storage.pointee.tail.load(ordering: .acquiring)) else {
            storage.pointee.dropped.wrappingIncrement(ordering: .relaxed)
            return
        }
        let (left, right) = (storage.pointee.left, storage.pointee.right)
        let mask = capacity - 1
        for frame in 0..<frames {
            left[(head + frame) & mask] = 0
            right[(head + frame) & mask] = 0
        }
        let leftMask = storage.pointee.leftMask.load(ordering: .relaxed)
        let rightMask = storage.pointee.rightMask.load(ordering: .relaxed)
        var channel = 0
        for index in 0..<count {
            let buffer = buffers[index]
            let width = Int(buffer.mNumberChannels)
            defer { channel += width }
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            for offset in 0..<width where channel + offset < 64 {
                let bit = UInt64(1) << UInt64(channel + offset)
                let toLeft = leftMask & bit != 0
                let toRight = rightMask & bit != 0
                guard toLeft || toRight else { continue }
                for frame in 0..<frames {
                    let sample = data[frame * width + offset]
                    if toLeft { left[(head + frame) & mask] += sample }
                    if toRight { right[(head + frame) & mask] += sample }
                }
            }
        }
        storage.pointee.head.store(head + frames, ordering: .releasing)
    }

    /// Asks the rule what to do, copies the frames, and moves `tail`. A drop reads one frame more
    /// than the call, and a repeat reads one less and plays its last frame two times. While the
    /// speaker flag is true, the render still pops, so the delay stays at the target, and writes
    /// zeros.
    private static func pull(
        _ storage: UnsafeMutablePointer<Storage>, frames: Int, left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>
    ) {
        let head = storage.pointee.head.load(ordering: .acquiring)
        let tail = storage.pointee.tail.load(ordering: .relaxed)
        let pushed = storage.pointee.lastPush.load(ordering: .relaxed)
        let silent = storage.pointee.speakers.load(ordering: .relaxed) & 1 == 1
        guard
            case .play(let skip, let read) = storage.pointee.rule.pull(
                frames: frames, available: head - tail, pushed: pushed)
        else {
            left.update(repeating: 0, count: frames)
            right.update(repeating: 0, count: frames)
            return
        }
        let start = tail + skip
        let copied = min(read, frames)
        copy(from: storage.pointee.left, at: start, to: left, count: copied)
        copy(from: storage.pointee.right, at: start, to: right, count: copied)
        for frame in copied..<frames {
            left[frame] = copied > 0 ? left[copied - 1] : 0
            right[frame] = copied > 0 ? right[copied - 1] : 0
        }
        storage.pointee.tail.store(start + read, ordering: .releasing)
        if silent {
            left.update(repeating: 0, count: frames)
            right.update(repeating: 0, count: frames)
        }
    }

    /// Copies `count` frames of one side out of the ring at the frame count `position`, in two
    /// parts when they cross the end.
    private static func copy(
        from side: UnsafeMutablePointer<Float>, at position: Int, to target: UnsafeMutablePointer<Float>, count: Int
    ) {
        let index = position & (capacity - 1)
        let first = min(count, capacity - index)
        target.update(from: side + index, count: first)
        (target + first).update(from: side, count: count - first)
    }
}
