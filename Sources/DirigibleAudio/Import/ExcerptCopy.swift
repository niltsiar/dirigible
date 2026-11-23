import AVFoundation
import DirigibleCore
import Foundation

/// The session half of a copy of the files of an excerpt into a package (decision 0042): a new
/// record for each file under a new stem, the scale at another rate, the map of the excerpt to the
/// new records, and `place` of the mapped excerpt, on a copy of the session. For a clipboard of the
/// same package, nothing copies and `place` gets the excerpt as it is.
struct ExcerptCopyPlan<Value> {
    var session: Session
    var value: Value
    /// The source record and the new record of each file to copy, in the order of the source IDs.
    var copies: [(record: AudioFile, copy: AudioFile)]

    /// `lengths` and `gains` are by source file ID. `stems` keeps the stems of an earlier plan.
    init(
        _ excerpt: Excerpt, same: Bool, into session: Session, in package: URL, lengths: [FileID: Frames],
        gains: [FileID: Gain], stems: [FileID: String]?, place: (inout Session, Excerpt) throws(SessionError) -> Value
    ) throws(SessionError) {
        var session = session
        var copies: [(record: AudioFile, copy: AudioFile)] = []
        var placed = excerpt
        if !same {
            if excerpt.sampleRate != session.sampleRate {
                placed = excerpt.resampled(to: session.sampleRate, lengths: lengths, gains: gains)
            } else if !gains.isEmpty {
                placed = excerpt.adding(gains)
            }
            var records: [FileID: AudioFile] = [:]
            for id in excerpt.files.keys.sorted() {
                guard let record = excerpt.files[id] else { continue }
                let stem =
                    stems?[id] ?? importStem(of: URL(filePath: record.path), in: session, package: package, taken: [])
                let copy = AudioFile(
                    id: FileID(stem), path: "\(stem).wav", layout: record.layout, length: lengths[id] ?? record.length)
                try session.addFile(copy)
                records[id] = copy
                copies.append((record, copy))
            }
            placed = try placed.mapped(to: records)
        }
        value = try place(&session, placed)
        self.session = session
        self.copies = copies
    }
}

/// Copies each file that the clips of `clipboard` name from `Clips/` of `source` into `Clips/` of
/// `package` under a new file ID (the stem rule of 0040), and runs `place` on a copy of `session`
/// with the excerpt mapped to the new records (decision 0042). A clone on one volume that can clone,
/// else a copy; at another sample rate, the conversion of import, and the clip edges scale to the
/// nearest frame (`Excerpt.resampled`). The order: the stems and `place` with the predicted lengths
/// (a refusal moves no byte), the source and space checks, the copies or conversions into
/// `.<stem>.wav.tmp` with a flush and a read-back, `place` again on `session` with the real
/// converted lengths, the cancel check, the renames, the flush of `Clips/`. It never writes
/// `session.xml`. A throw before the first rename leaves no new name in `Clips/`; after it, nothing
/// deletes a renamed WAV (0040). The track paste (`pasteClipboard`) and the favorite add
/// (`Favorites.add`) call it. `spans` gives, by record ID, the source frames that a record copies
/// (`Excerpt.cropped`); a record with no span copies its whole file.
func copyExcerptFiles<Value>(
    _ clipboard: Clipboard, from source: URL, into session: Session, in package: URL, identity: PackageID?,
    spans: [FileID: Range<Frames>] = [:], freeBytes: () -> Int64, canClone: (URL, URL) -> Bool,
    progress: @escaping (Double) -> Void, isCancelled: @escaping () -> Bool, flush: @escaping (String) -> Int32?,
    place: (inout Session, Excerpt) throws(SessionError) -> Value
) throws(PasteError) -> (session: Session, value: Value) {
    let excerpt = clipboard.excerpt
    let same = PackageID.same(clipboard.origin, identity)
    let rate = session.sampleRate
    let converts = !same && excerpt.sampleRate != rate
    // The scale rule has one owner: `Excerpt.resampled` gives the predicted converted lengths.
    let predicted = (converts ? excerpt.resampled(to: rate, lengths: [:]) : excerpt).files.mapValues(\.length)
    let plan: ExcerptCopyPlan<Value>
    do throws(SessionError) {
        plan = try ExcerptCopyPlan(
            excerpt, same: same, into: session, in: package, lengths: predicted, gains: [:], stems: nil, place: place)
    } catch {
        throw .session(error)
    }
    guard !plan.copies.isEmpty else {
        guard !isCancelled() else { throw .cancelled }
        return (plan.session, plan.value)
    }
    if clipboard.origin != nil, !PackageID.same(PackageID(lockFileOf: source), clipboard.origin) {
        throw .sourceMissing(file: source.lastPathComponent)
    }
    var final = plan
    try copyFiles(
        plan.copies, from: source, to: package, rates: (rate, excerpt.sampleRate), spans: spans, freeBytes: freeBytes,
        canClone: canClone, progress: progress, isCancelled: isCancelled, flush: flush
    ) { (converted: [FileID: (length: Frames, gain: Gain)]) throws(PasteError) in
        guard !converted.isEmpty else { return }
        // The real lengths differ from the prediction (the converter floors, and a record can be
        // shorter than its file), and a cut can add a gain: place again with them, before the renames.
        do throws(SessionError) {
            final = try ExcerptCopyPlan(
                excerpt, same: false, into: session, in: package,
                lengths: converted.mapValues(\.length), gains: converted.mapValues(\.gain),
                stems: Dictionary(uniqueKeysWithValues: plan.copies.map { ($0.record.id, $0.copy.id.rawValue) }),
                place: place)
        } catch {
            throw .session(error)
        }
    }
    return (final.session, final.value)
}

/// The file half of `copyExcerptFiles`: the checks, the copies, the conversions (when the rates
/// differ), and the cuts (a record with a span), the read-back, `beforeRenames` with the frames and the
/// gain of each converted or cut file, and the renames, with `NewClipFiles` (decision 0056).
private func copyFiles(
    _ copies: [(record: AudioFile, copy: AudioFile)], from source: URL, to package: URL,
    rates: (target: Int, source: Int), spans: [FileID: Range<Frames>],
    freeBytes: () -> Int64, canClone: (URL, URL) -> Bool, progress: @escaping (Double) -> Void,
    isCancelled: @escaping () -> Bool, flush: @escaping (String) -> Int32?,
    beforeRenames: ([FileID: (length: Frames, gain: Gain)]) throws(PasteError) -> Void
) throws(PasteError) {
    let converts = rates.target != rates.source
    var sizes: [Int64] = []
    var pairs: [(source: URL, size: Int64, target: URL)] = []
    var whole: [Int] = []
    var writtenBytes: Int64 = 0
    for (index, (record, copy)) in copies.enumerated() {
        // A link in Clips/ of the source copies as its target: clonefile and copyfile follow it.
        let url = source.appending(path: "\(clipsFolderName)/\(record.path)")
        guard sourceIsDownloaded(url) else { throw .notDownloaded(file: record.path) }
        var info = stat()
        guard stat(url.path, &info) == 0 else {
            throw errno == ENOENT ? .sourceMissing(file: record.path) : .write(file: record.path, errno: errno)
        }
        // A FIFO would hold the AVAudioFile read below until a writer came.
        guard info.st_mode & S_IFMT == S_IFREG else { throw .sourceChanged(file: record.path) }
        let span = spans[record.id]
        guard converts || span != nil else {
            sizes.append(Int64(info.st_size))
            pairs.append((url, Int64(info.st_size), package))
            whole.append(index)
            continue
        }
        // A conversion reads the whole file and a cut its span, so those frames count (0040).
        let frames =
            span.map { Int64(($0.upperBound - $0.lowerBound).count) }
            ?? (try? AVAudioFile(forReading: url).length).map { Int64($0) } ?? Int64(record.length.count)
        let written = wavFileBytes(
            frames: (frames * Int64(rates.target) + Int64(rates.source) - 1) / Int64(rates.source),
            channels: copy.layout.channelCount)
        sizes.append(span == nil ? Int64(info.st_size) : written)
        writtenBytes += written
    }
    let (wholeClones, copiedBytes) = copyNeed(pairs, canClone: canClone)
    var clones = copies.map { _ in false }
    for (index, clone) in zip(whole, wholeClones) { clones[index] = clone }
    let needed = copiedBytes + writtenBytes
    // One check for all files, so a paste cannot pass file by file and fill the disk late.
    var files: NewClipFiles
    do throws(NewClipFault) {
        files = try NewClipFiles(in: package, bytes: needed, freeBytes: freeBytes, flush: flush)
    } catch {
        throw PasteError(error)
    }
    defer { files.discard() }
    let total = max(sizes.reduce(0, +), 1)
    var done: Int64 = 0
    var converted: [FileID: (length: Frames, gain: Gain)] = [:]
    for (index, (record, copy)) in copies.enumerated() {
        let size = sizes[index]
        guard !isCancelled() else { throw .cancelled }
        let from = source.appending(path: "\(clipsFolderName)/\(record.path)")
        let temporary: URL
        do throws(NewClipFault) {
            temporary = try files.add(stem: (copy.path as NSString).deletingPathExtension)
        } catch {
            throw PasteError(error)
        }
        let base = done
        if converts || spans[record.id] != nil {
            let share = { (fraction: Double) in progress((Double(base) + fraction * Double(size)) / Double(total)) }
            converted[record.id] = try convert(
                from, record: record, copy: copy, rate: rates.target, span: spans[record.id], into: temporary,
                package: package, progress: share, isCancelled: isCancelled)
        } else {
            let context = CopyContext(isCancelled: isCancelled) { progress(Double(base + $0) / Double(total)) }
            if let code = copyFile(from, to: temporary, clone: clones[index], context: context) {
                if code == ECANCELED { throw .cancelled }
                throw copyFault(code, from: from, record: record, copy: copy)
            }
            // Its data is on disk before the rename; a conversion flushes in `ClipConversion`.
            if let code = flush(temporary.path) { throw .write(file: copy.path, errno: code) }
            guard let read = try? AVAudioFile(forReading: temporary),
                // At least the record length, as `openMedia` reads it: a record can be shorter.
                read.length >= AVAudioFramePosition(copy.length.count),
                Int(read.fileFormat.channelCount) == copy.layout.channelCount
            else { throw .sourceChanged(file: record.path) }
        }
        done += size
        progress(Double(done) / Double(total))
    }
    try beforeRenames(converted)
    guard !isCancelled() else { throw .cancelled }
    do throws(NewClipFault) { try files.commit() } catch { throw PasteError(error) }
}

/// One conversion of a pool WAV, or of its `span`, into `temporary` at `rate`, through the
/// conversion of import (`convertToWAV`, 0040). At the rate of the file it keeps each sample.
/// `ClipConversion` flushes the WAV and reads its length back.
private func convert(
    _ source: URL, record: AudioFile, copy: AudioFile, rate: Int, span: Range<Frames>?, into temporary: URL,
    package: URL, progress: @escaping (Double) -> Void, isCancelled: @escaping () -> Bool
) throws(PasteError) -> (length: Frames, gain: Gain) {
    do throws(ImportError) {
        let (descriptor, input) = try openAudio(source)
        defer { close(descriptor) }
        guard Int(input.fileFormat.channelCount) == record.layout.channelCount,
            input.length >= (span?.upperBound ?? record.length).count
        else { throw .notAudio(file: record.path) }
        guard
            let (length, gain) = try convertToWAV(
                input, descriptor: descriptor, source: source, package: package,
                wav: "\(clipsFolderName)/\(copy.path)", channels: record.layout.channelCount, rate: Double(rate),
                span: span.map { Int64($0.lowerBound.count)..<Int64($0.upperBound.count) },
                into: temporary, progress: progress, isCancelled: isCancelled)
        else { throw isCancelled() ? .cancelled : .notAudio(file: record.path) }
        return (Frames(length), gain)
    } catch {
        switch error {
        case .cancelled: throw .cancelled
        case .notAudio, .tooManyChannels: throw .sourceChanged(file: record.path)
        case .notDownloaded: throw .notDownloaded(file: record.path)
        case .unreadable(_, let code):
            throw code == ENOENT ? .sourceMissing(file: record.path) : .convert(file: record.path, errno: code)
        case .write(_, .readFailed(_, let code)), .write(_, .segmentUnreadable(_, _, let code)):
            throw .convert(file: copy.path, errno: code)
        case .write(_, .writeFailed(_, let code)):
            // A full disk keeps its own alert, as for a copy.
            throw code == ENOSPC ? .write(file: copy.path, errno: code) : .convert(file: copy.path, errno: code)
        case .space, .session: throw .convert(file: copy.path, errno: EIO)
        }
    }
}
