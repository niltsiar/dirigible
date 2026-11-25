import DirigibleCore
import Foundation

extension Studio {
    /// The presets of the running preset set, in file order: the preset of the file in hand is at
    /// `exportFile.number - 1`. Nil when no preset set runs.
    public var exportPresetRefs: [PresetRef]? { exportJob?.presets }

    /// Exports one file of `source` of the session of now for each of `presets` to `folder`, with
    /// the names of `presetTargets` (decision 0080). It is one export job, as the split export: it
    /// throws `.busy` as `export`, and a take start in this or another studio, `settle()`, Cancel,
    /// and a cancel of the caller stop the whole set with `.exportPresets(.stopped(_))`, with the
    /// finished files on disk; `exportStop` gives the cause. A rate that a preset cannot write and two
    /// presets of one file name throw `.exportPresets(_)` and start no job. With no preset it starts no job and
    /// returns no file. `exportFile` gives the file in hand, and `exportPresetRefs` its preset.
    /// `introTitle` names the chapter that the export adds before a first chapter after the start.
    public func export(
        presets: [(ref: PresetRef, options: PresetOptions)], source: ExportSource, folder: URL, prefix: String,
        replacing: [URL: ConfirmedFile], introTitle: String = "Intro",
        progress: @escaping @MainActor @Sendable (Double) -> Void = { _ in }
    ) async throws(StudioError) -> [ExportedPreset] {
        try checkNotBusy()
        try checkReadable(.export)
        guard pendingTake == nil, exportJob == nil, !settling else { throw .busy }
        let targets: [ExportPresetTarget]
        do throws(ExportPresetsError) {
            targets = try presetTargets(presets, folder: folder, prefix: prefix, sessionRate: session.sampleRate)
        } catch {
            throw .exportPresets(error)
        }
        guard let first = targets.first else { return [] }
        exportNumber += 1
        exportStop = nil
        let number = exportNumber
        let session = session
        let hop: @Sendable (ExportPartsProgress) -> Void = { [weak self] file in
            Task { @MainActor in self?.exportPartProgressed(number, file) }
        }
        let task = jobTask { package, isCancelled in
            Result { () throws(ExportPresetsError) in
                try exportPresets(
                    session, source: source, presets: presets, folder: folder, prefix: prefix, introTitle: introTitle,
                    replacing: replacing,
                    package: package, progress: hop, isCancelled: isCancelled)
            }
        }
        exportJob = ExportJob(
            number: number, url: first.url, progress: 0, report: progress, task: Self.handle(task),
            presets: targets.map(\.preset))
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if exportJob?.number == number { exportJob = nil }
        do { return try result.get() } catch { throw .exportPresets(error) }
    }
}
