import DirigibleCore
import Foundation

/// One file of a preset set and its path.
public struct ExportPresetTarget: Hashable, Sendable {
    public let preset: PresetRef
    public let options: PresetOptions
    public let url: URL
}

/// One file that a preset set wrote.
public struct ExportedPreset: Hashable, Sendable {
    public let preset: PresetRef
    public let url: URL
    public let result: ExportResult
}

/// A preset set that stopped or failed after the check of its targets.
public struct ExportPresetsStop: Hashable, Sendable {
    /// `.cancelled` for a stop: Cancel, a take, a close, or a cancel of the caller.
    public let error: ExportError
    /// The files on disk, in preset order.
    public let written: [ExportedPreset]
    /// The targets of the preset in hand and of each preset after it. An old item at each one stays.
    public let remaining: [URL]
}

public enum ExportPresetsError: Error, Hashable, Sendable {
    /// An item is at each of these targets and `replacing` does not hold it. Nothing was written.
    case exists([URL])
    /// Two presets or more give each of these targets one file name. Nothing was written.
    case duplicateTargets([URL])
    /// The format of the preset cannot be written at the rate in hertz. Nothing was written.
    case rateNotSupported(PresetRef, Int)
    case stopped(ExportPresetsStop)
}

/// The targets of a preset set (decision 0080): one file for each preset, named by
/// `Session.presetFileNames` in `folder`. The one owner of the target URLs: the keys of `replacing`
/// of `exportPresets` come from it. Two targets or more whose names are equal with case and Unicode
/// normalization folded (a volume can fold both) throw `.duplicateTargets` with each such URL.
public func presetTargets(
    _ presets: [(ref: PresetRef, options: PresetOptions)], folder: URL, prefix: String
) throws(ExportPresetsError) -> [ExportPresetTarget] {
    let names = Session.presetFileNames(
        presets.map { ($0.ref, $0.options.format.pathExtension) }, prefix: prefix, limit: exportNameLimit)
    let keys = names.map { $0.precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: nil) }
    let counts = Dictionary(keys.map { ($0, 1) }, uniquingKeysWith: +)
    let targets = zip(presets, names).map {
        ExportPresetTarget(preset: $0.ref, options: $0.options, url: folder.appending(path: $1))
    }
    let duplicates = zip(keys, targets).filter { counts[$0.0, default: 0] > 1 }.map(\.1.url)
    guard duplicates.isEmpty else { throw .duplicateTargets(duplicates) }
    return targets
}

/// Exports one file of `source` of `session` for each of `presets`, to the targets of
/// `presetTargets` (decision 0080). Before the first file it refuses two targets of one name, a
/// preset whose format `exportMix` refuses at its rate in `session`, and an item at a target that
/// `replacing` does not hold as the same device and inode. Then `exportItems` runs `exportMix` for
/// each preset with its own options, so each file has its own loudness gain. A stop or a failure in
/// file k throws `.stopped`: the files before file k stay, and file k leaves no file. `progress`
/// gets the fraction of the set by frames at each new whole percent and at the start of each file.
/// Thread rule: as `exportMix`.
public func exportPresets(
    _ session: Session, source: ExportSource, presets: [(ref: PresetRef, options: PresetOptions)], folder: URL,
    prefix: String, replacing: [URL: ConfirmedFile], package: () throws(SessionFileError) -> URL,
    progress: (ExportPartsProgress) -> Void = { _ in }, isCancelled: () -> Bool = { Task.isCancelled }
) throws(ExportPresetsError) -> [ExportedPreset] {
    let targets = try presetTargets(presets, folder: folder, prefix: prefix)
    for target in targets {
        let rate = target.options.rate.hertz(session: session.sampleRate)
        guard exportSupports(target.options.format, rate: rate) else { throw .rateNotSupported(target.preset, rate) }
    }
    let items = targets.map {
        ExportItem(session: session, source: source, options: ExportOptions($0.options), url: $0.url)
    }
    func files(_ results: [ExportResult]) -> [ExportedPreset] {
        zip(targets, results).map { ExportedPreset(preset: $0.preset, url: $0.url, result: $1) }
    }
    do throws(ExportItemsError) {
        let results = try exportItems(
            items, replacing: replacing, package: package,
            progress: { fraction, index in
                progress(
                    ExportPartsProgress(
                        fraction: fraction, number: index + 1, count: targets.count,
                        name: targets[index].url.lastPathComponent))
            }, isCancelled: isCancelled)
        return files(results)
    } catch {
        switch error {
        case .exists(let urls): throw .exists(urls)
        case .stopped(let stop):
            throw .stopped(
                ExportPresetsStop(error: stop.error, written: files(stop.written), remaining: stop.remaining))
        }
    }
}

extension ExportOptions {
    /// The export options of a preset.
    public init(_ preset: PresetOptions) {
        self.init(format: preset.format, layout: preset.layout, rate: preset.rate, loudness: preset.loudness)
    }
}
