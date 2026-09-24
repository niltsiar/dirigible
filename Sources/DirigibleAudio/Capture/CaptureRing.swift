import Atomics
import CoreAudio

/// The SPSC byte ring of one appearance of a device (decisions 0005 and 0013). It holds pointers
/// and `UnsafeAtomic` values only, so a copy is the same ring and nothing in it uses ARC.
///
/// Record layout (8-aligned; in the ring only, never on disk): UInt32 record bytes, UInt32 frame
/// count, Float64 sample time, UInt64 host time in ticks, Float64 rate hint, UInt32 time flags,
/// UInt32 buffer count n, n x (UInt32 channels, UInt32 bytes), then the bytes of each buffer.
///
/// `head` and `tail` are monotonic byte counts. The producer loads `tail` acquiring and stores
/// `head` releasing. The consumer loads `head` acquiring and stores `tail` releasing.
struct CaptureRing: @unchecked Sendable {
    private struct Storage {
        let bytes: UnsafeMutableRawPointer
        let capacity: Int
        let head: UnsafeAtomic<Int>
        let tail: UnsafeAtomic<Int>
        let dropped: UnsafeAtomic<Int>
        /// The bit pattern of the rate hint.
        let rate: UnsafeAtomic<UInt64>
    }

    private static let headerBytes = 40
    private let storage: UnsafeMutablePointer<Storage>

    /// `capacity` is a power of two, 64 bytes or more. Writes zeros to every byte, so the IO
    /// thread never touches a new page first.
    init(capacity: Int, rate: Double) {
        precondition(capacity >= 64 && capacity & (capacity - 1) == 0, "the ring capacity is a power of two")
        let bytes = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
        bytes.initializeMemory(as: UInt8.self, repeating: 0, count: capacity)
        storage = .allocate(capacity: 1)
        storage.initialize(
            to: Storage(
                bytes: bytes, capacity: capacity, head: .create(0), tail: .create(0), dropped: .create(0),
                rate: .create(rate.bitPattern)))
    }

    /// Room for `seconds` at the highest available rate (or the nominal rate) of every input
    /// channel, plus 25% for the record headers, rounded up to a power of two.
    init(device: InputDevice, seconds: Double) {
        let rate = device.availableRates.map(\.upperBound).reduce(device.nominalRate, max)
        let bytes = Int((seconds * rate * Double(device.channelCount) * 4 * 1.25).rounded(.up))
        self.init(capacity: max(64, 1 << (Int.bitWidth - (bytes - 1).leadingZeroBitCount)), rate: device.nominalRate)
    }

    /// Only after every IOProc call that can use the ring has returned: a clean detach.
    func deallocate() {
        let storage = storage.pointee
        storage.head.destroy()
        storage.tail.destroy()
        storage.dropped.destroy()
        storage.rate.destroy()
        storage.bytes.deallocate()
        self.storage.deinitialize(count: 1)
        self.storage.deallocate()
    }

    /// The client data of the IOProc.
    var context: UnsafeMutableRawPointer { UnsafeMutableRawPointer(storage) }

    /// The IOProc. A static C function of a nonisolated type: it captures nothing, and it is not
    /// isolated to an actor (probe P1b). It only copies the input into the ring.
    static let ioProc: AudioDeviceIOProc = { _, _, input, inputTime, _, _, context in
        guard let context else { return noErr }
        CaptureRing.push(context.assumingMemoryBound(to: Storage.self), inputTime, input)
        return noErr
    }

    /// The rate listener of this appearance. A hint (decision 0004), so relaxed. A rate that is
    /// not `isValidRate` is ignored.
    func setRate(_ rate: Double) {
        guard isValidRate(rate) else { return }
        storage.pointee.rate.store(rate.bitPattern, ordering: .relaxed)
    }

    /// Producer only. True when the ring has room for the record of `input`.
    func hasRoom(for input: UnsafePointer<AudioBufferList>) -> Bool {
        Self.hasRoom(storage, Self.recordBytes(input))
    }

    /// Consumer only. The dropped frames since the last call.
    func takeDroppedFrames() -> Int {
        storage.pointee.dropped.exchange(0, ordering: .relaxed)
    }

    /// Consumer only. Allocates. `record` is nil when the record has no valid sample and host
    /// times: the writer ends the segment.
    func pop() -> RingRecord? {
        let ring = storage.pointee
        let tail = ring.tail.load(ordering: .relaxed)
        guard ring.head.load(ordering: .acquiring) != tail else { return nil }
        func load<T>(_ offset: Int, as type: T.Type) -> T {
            ring.bytes.load(fromByteOffset: (tail + offset) & (ring.capacity - 1), as: type)
        }
        let size = Int(load(0, as: UInt32.self))
        let frames = Int(load(4, as: UInt32.self))
        let sampleTime = Double(bitPattern: load(8, as: UInt64.self))
        let hostTime = load(16, as: UInt64.self)
        let rate = Double(bitPattern: load(24, as: UInt64.self))
        let flags = AudioTimeStampFlags(rawValue: load(32, as: UInt32.self))
        let count = Int(load(36, as: UInt32.self))
        var position = tail + Self.headerBytes + 8 * count
        let buffers = (0..<count).map { index in
            let bytes = Int(load(Self.headerBytes + 8 * index + 4, as: UInt32.self))
            defer { position += bytes }
            return [Float](unsafeUninitializedCapacity: bytes / 4) { samples, initialized in
                initialized = bytes / 4
                guard let target = samples.baseAddress else { return }
                Self.copy(from: storage, at: position, to: UnsafeMutableRawPointer(target), count: initialized * 4)
            }
        }
        ring.tail.store(tail + size, ordering: .releasing)
        guard flags.contains([.sampleTimeValid, .hostTimeValid]) else { return RingRecord(record: nil, frames: frames) }
        return RingRecord(
            record: InputRecord(
                sampleTime: sampleTime, hostTimeNanos: AudioConvertHostTimeToNanos(hostTime), frameCount: frames,
                nominalRate: rate, buffers: buffers),
            frames: frames)
    }

    // MARK: Real-time path: pointer math, memcpy, and atomic loads and stores only.

    /// The record bytes of `input`, padded to 8.
    private static func recordBytes(_ input: UnsafePointer<AudioBufferList>) -> Int {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        var size = headerBytes + 8 * list.count
        for index in 0..<list.count { size += Int(list[index].mDataByteSize) }
        return (size + 7) & ~7
    }

    private static func hasRoom(_ storage: UnsafeMutablePointer<Storage>, _ size: Int) -> Bool {
        let ring = storage.pointee
        return size <= ring.capacity - (ring.head.load(ordering: .relaxed) - ring.tail.load(ordering: .acquiring))
    }

    /// Copies one record, or adds its frames to the dropped-frame counter when the ring has no
    /// room for all of it. Never a partial record.
    private static func push(
        _ storage: UnsafeMutablePointer<Storage>, _ time: UnsafePointer<AudioTimeStamp>,
        _ input: UnsafePointer<AudioBufferList>
    ) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard list.count > 0, list[0].mNumberChannels > 0 else { return }
        let ring = storage.pointee
        let frames = Int(list[0].mDataByteSize) / (4 * Int(list[0].mNumberChannels))
        let size = recordBytes(input)
        guard hasRoom(storage, size) else {
            ring.dropped.wrappingIncrement(by: frames, ordering: .relaxed)
            return
        }
        let head = ring.head.load(ordering: .relaxed)
        let mask = ring.capacity - 1
        // Every header field is at its own alignment, and the capacity is a multiple of 8, so no
        // field crosses the end.
        ring.bytes.storeBytes(of: UInt32(size), toByteOffset: head & mask, as: UInt32.self)
        ring.bytes.storeBytes(of: UInt32(frames), toByteOffset: (head + 4) & mask, as: UInt32.self)
        ring.bytes.storeBytes(of: time.pointee.mSampleTime.bitPattern, toByteOffset: (head + 8) & mask, as: UInt64.self)
        ring.bytes.storeBytes(of: time.pointee.mHostTime, toByteOffset: (head + 16) & mask, as: UInt64.self)
        ring.bytes.storeBytes(
            of: ring.rate.load(ordering: .relaxed), toByteOffset: (head + 24) & mask, as: UInt64.self)
        ring.bytes.storeBytes(of: time.pointee.mFlags.rawValue, toByteOffset: (head + 32) & mask, as: UInt32.self)
        ring.bytes.storeBytes(of: UInt32(list.count), toByteOffset: (head + 36) & mask, as: UInt32.self)
        var position = head + headerBytes + 8 * list.count
        for index in 0..<list.count {
            let buffer = list[index]
            let offset = head + headerBytes + 8 * index
            ring.bytes.storeBytes(of: buffer.mNumberChannels, toByteOffset: offset & mask, as: UInt32.self)
            ring.bytes.storeBytes(of: buffer.mDataByteSize, toByteOffset: (offset + 4) & mask, as: UInt32.self)
            copy(buffer.mData, count: Int(buffer.mDataByteSize), to: storage, at: position)
            position += Int(buffer.mDataByteSize)
        }
        ring.head.store(head + size, ordering: .releasing)
    }

    /// Copies `count` bytes into the ring at the byte count `position`, in two parts when they
    /// cross the end. A nil source writes zeros.
    private static func copy(
        _ source: UnsafeMutableRawPointer?, count: Int, to storage: UnsafeMutablePointer<Storage>, at position: Int
    ) {
        let ring = storage.pointee
        let index = position & (ring.capacity - 1)
        let first = min(count, ring.capacity - index)
        if let source {
            memcpy(ring.bytes + index, source, first)
            memcpy(ring.bytes, source + first, count - first)
        } else {
            memset(ring.bytes + index, 0, first)
            memset(ring.bytes, 0, count - first)
        }
    }

    /// Copies `count` bytes out of the ring at the byte count `position`.
    private static func copy(
        from storage: UnsafeMutablePointer<Storage>, at position: Int, to target: UnsafeMutableRawPointer, count: Int
    ) {
        let ring = storage.pointee
        let index = position & (ring.capacity - 1)
        let first = min(count, ring.capacity - index)
        memcpy(target, ring.bytes + index, first)
        memcpy(target + first, ring.bytes, count - first)
    }
}

/// One ring record after `pop`. `record` is nil when the record has no valid times.
struct RingRecord {
    let record: InputRecord?
    let frames: Int
}
