import Atomics
import CoreAudio

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
        /// The speaker flag in bit 0, and the ticket of its store above it.
        let speakers: UnsafeAtomic<UInt64>
        /// Only the render reads or writes it.
        var rule: DriftRule
    }

    private let storage: UnsafeMutablePointer<Storage>

    /// Writes zeros to every frame, so the IO threads never touch a new page first. The speaker
    /// flag starts true: the render plays zeros until the first read of the default output.
    init(rate: Double, inputBlock: Int, pull: Int) {
        let left = UnsafeMutablePointer<Float>.allocate(capacity: Self.capacity)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: Self.capacity)
        left.initialize(repeating: 0, count: Self.capacity)
        right.initialize(repeating: 0, count: Self.capacity)
        storage = .allocate(capacity: 1)
        storage.initialize(
            to: Storage(
                left: left, right: right, head: .create(0), tail: .create(0), leftMask: .create(0),
                rightMask: .create(0), lastPush: .create(0), dropped: .create(0), speakers: .create(1),
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
        for atomic in [ring.leftMask, ring.rightMask, ring.speakers] { atomic.destroy() }
        storage.deinitialize(count: 1)
        storage.deallocate()
    }

    /// The client data of the IOProc and the render.
    var context: UnsafeMutableRawPointer { UnsafeMutableRawPointer(storage) }

    /// The next push uses `map`. The frames in the ring keep the map of their push.
    func setMap(_ map: ChannelMap) {
        storage.pointee.leftMask.store(map.left, ordering: .relaxed)
        storage.pointee.rightMask.store(map.right, ordering: .relaxed)
    }

    var droppedPushes: Int { storage.pointee.dropped.load(ordering: .relaxed) }

    /// True while the render must play zeros: the default output is the built-in speakers.
    var speakers: Bool { storage.pointee.speakers.load(ordering: .relaxed) & 1 == 1 }

    func storeSpeakers(_ speakers: Bool, ticket: UInt64) {
        storage.pointee.speakers.store(ticket << 1 | (speakers ? 1 : 0), ordering: .relaxed)
    }

    /// The IOProc side.
    func push(_ input: UnsafePointer<AudioBufferList>) { Self.push(storage, input) }

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
        let ring = storage.pointee
        ring.lastPush.store(frames, ordering: .relaxed)
        let head = ring.head.load(ordering: .relaxed)
        guard frames <= capacity - (head - ring.tail.load(ordering: .acquiring)) else {
            ring.dropped.wrappingIncrement(ordering: .relaxed)
            return
        }
        let mask = capacity - 1
        for frame in 0..<frames {
            ring.left[(head + frame) & mask] = 0
            ring.right[(head + frame) & mask] = 0
        }
        let leftMask = ring.leftMask.load(ordering: .relaxed)
        let rightMask = ring.rightMask.load(ordering: .relaxed)
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
                    if toLeft { ring.left[(head + frame) & mask] += sample }
                    if toRight { ring.right[(head + frame) & mask] += sample }
                }
            }
        }
        ring.head.store(head + frames, ordering: .releasing)
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
