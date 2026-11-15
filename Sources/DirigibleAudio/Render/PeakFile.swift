import DirigibleCore
import Foundation

/// The peak cache file, version 2 (decision 0017): a 64-byte little-endian header, then the bins
/// of each level as a UInt32 peak and a UInt32 RMS. The cache file is a boundary: the reader
/// refuses a file whose fields do not match the WAV, and a refusal is a miss. The name holds the
/// version (decision 0024 P5), so a build of version 1 (UInt16 values) does not read or write the
/// file of version 2, and the pass computes the peaks again next to a file of version 1.
public enum PeakFile {
    /// The cache folder of the command-line front end, the folder of the app of the real ID.
    public static let folder = folder(bundleID: "com.delineas.dirigible", caches: .cachesDirectory)

    /// The cache folder of the app with `bundleID` in the Caches folder `caches`.
    public static func folder(bundleID: String, caches: URL) -> URL {
        caches.appending(path: "\(bundleID)/Peaks")
    }

    static let magic = Array("DIRPEAKS".utf8)
    static let version: UInt32 = 2
    static let headerSize = 64
    /// The bytes of one bin: the header field at offset 28.
    static let binBytes = 8

    /// The characters of a pool path that stay in a name. `-` separates the fields of a name,
    /// so it is escaped, and the prefix `<escaped path>-` of one pool file is not the prefix of another.
    private static let kept = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._~")

    static func escape(_ path: String) -> String { path.addingPercentEncoding(withAllowedCharacters: kept)! }

    static func name(path: String, stamp: FileStamp) -> String {
        "\(escape(path))-\(stamp.size)-\(stamp.seconds)-\(stamp.nanoseconds).v\(version).peaks"
    }

    static func encode(_ peaks: Peaks) -> Data {
        var data = Data(magic)
        let fields: [UInt32] = [
            version, UInt32(Peaks.binFrames[0]), UInt32(peaks.levels.count), UInt32(peaks.channels),
            UInt32(peaks.sampleRate), UInt32(binBytes),
        ]
        for field in fields { append(field, to: &data) }
        for field in [peaks.stamp.size, Int64(peaks.stamp.seconds), Int64(peaks.stamp.nanoseconds)] {
            append(field, to: &data)
        }
        append(UInt64(peaks.frames.count), to: &data)
        for level in peaks.levels {
            var values = [UInt32]()
            values.reserveCapacity(level.count * 2)
            for column in level { values += [column.peak.littleEndian, column.rms.littleEndian] }
            values.withUnsafeBytes { data.append(contentsOf: $0) }
        }
        return data
    }

    /// The peaks of `data`, or nil when a field does not match the WAV or the file length does
    /// not match the frame count. `stamp`, `channels`, and `rate` are those of the WAV now.
    static func decode(_ data: Data, stamp: FileStamp, channels: Int, rate: Int) -> Peaks? {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Peaks? in
            guard raw.count >= headerSize, Array(raw[0..<8]) == magic else { return nil }
            func u32(_ offset: Int) -> UInt32 {
                UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
            }
            func i64(_ offset: Int) -> Int64 {
                Int64(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: Int64.self))
            }
            let frames = UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: 56, as: UInt64.self))
            // The bin counts derive from the frames, so no count field can disagree. The sums
            // cannot overflow for any UInt64 frame count.
            let counts = Peaks.binFrames.map { UInt64($0) }.map { frames / $0 + (frames % $0 == 0 ? 0 : 1) }
            guard u32(8) == version, u32(12) == UInt32(Peaks.binFrames[0]), u32(16) == UInt32(Peaks.binFrames.count),
                u32(20) == UInt32(channels), u32(24) == UInt32(rate), u32(28) == UInt32(binBytes),
                i64(32) == stamp.size, i64(40) == Int64(stamp.seconds), i64(48) == Int64(stamp.nanoseconds),
                UInt64(raw.count - headerSize) == UInt64(binBytes) * counts.reduce(0, +)
            else { return nil }
            var offset = headerSize
            let levels = counts.map { count in
                (0..<Int(count)).map { _ in
                    defer { offset += binBytes }
                    return PeakColumn(
                        peak32: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)),
                        rms32: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self)))
                }
            }
            return Peaks(
                frames: Frames(Int(frames)), stamp: stamp, channels: channels, sampleRate: rate, levels: levels)
        }
    }

    /// The peaks of the cache file of `path` with `stamp` in `folder`, or nil (a miss).
    static func read(path: String, stamp: FileStamp, channels: Int, rate: Int, in folder: URL) -> Peaks? {
        guard let data = try? Data(contentsOf: folder.appending(path: name(path: path, stamp: stamp))) else {
            return nil
        }
        return decode(data, stamp: stamp, channels: channels, rate: rate)
    }

    /// Writes through `.<name>.<UUID>.tmp` and rename(2), with no fsync (a cache). On an error it
    /// removes the temporary file. Every error is the same case for the caller: the peaks stay
    /// in memory.
    static func write(_ peaks: Peaks, path: String, in folder: URL) throws(POSIXError) {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch { throw POSIXError(.EIO) }
        let name = name(path: path, stamp: peaks.stamp)
        let temporary = folder.appending(path: ".\(name).\(UUID().uuidString).tmp").path
        let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw posix(errno) }
        var failure: Int32 = 0
        encode(peaks).withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(descriptor, raw.baseAddress! + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    failure = errno
                    return
                }
                offset += written
            }
        }
        if close(descriptor) != 0, failure == 0 { failure = errno }
        if failure == 0, rename(temporary, folder.appending(path: name).path) != 0 { failure = errno }
        guard failure != 0 else { return }
        unlink(temporary)
        throw posix(failure)
    }

    /// The time after which the launch removes a cache file that no pass used.
    public static let unusedLimit: TimeInterval = 90 * 86_400

    /// Marks the cache file of `path` with `stamp` as used: its modification time is now. The
    /// stamp of the WAV is in the name and the header, so the time of the cache file has no
    /// other use. An error leaves the time.
    static func touch(path: String, stamp: FileStamp, in folder: URL) {
        utimes(folder.appending(path: name(path: path, stamp: stamp)).path, nil)
    }

    /// Removes each file in `folder` that was not used since `cutoff`: a cache file, or the
    /// temporary file of a write that stopped. An error leaves the file. There is no prune at a
    /// write: pool paths repeat in each package, so a cache file of the same pool path with
    /// another stamp can be the peaks of another package.
    public static func prune(_ folder: URL, before cutoff: Date) {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        let files = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: Array(keys))
        for file in files ?? [] {
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true,
                let modified = values.contentModificationDate, modified < cutoff
            else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private static func posix(_ code: Int32) -> POSIXError { POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
}

/// The state of the cache file of one pool file.
public enum PeakCacheState: Hashable, Sendable {
    /// The cache file of the stamp of the WAV now decodes; `bins` is the count of level 0.
    case hit(bins: Int)
    /// No cache file of the stamp of the WAV now decodes.
    case miss
    /// `openMedia` gives `.missing`.
    case missing
}

/// The one public read of the peak cache (decision 0017), for `dirigible peaks`. For each pool
/// file in ID order: the stamp from `openMedia`, then the cache file of that stamp. It writes
/// nothing and takes no lock. Throws when the process has no free descriptor.
public func peakCacheStates(of session: Session, package: URL, cache: URL) throws(POSIXError) -> [(
    path: String, state: PeakCacheState
)] {
    let clips = package.appending(path: clipsFolderName)
    var states: [(path: String, state: PeakCacheState)] = []
    for file in session.files.values.sorted(by: { $0.id < $1.id }) {
        let opened = try openMedia(file, in: clips, rate: session.sampleRate)
        var state = PeakCacheState.miss
        if opened.fault == .missing {
            state = .missing
        } else if opened.file != nil, let stamp = opened.stamp,
            let peaks = PeakFile.read(
                path: file.path, stamp: stamp, channels: file.layout.channelCount, rate: session.sampleRate, in: cache)
        {
            state = .hit(bins: peaks.levels[0].count)
        }
        states.append((file.path, state))
    }
    return states
}
