import DirigibleAudio
import DirigibleCore
import Foundation

/// `export` and `render` through `Studio.export`: the window shows the export sheet, and a take
/// start, the sheet Cancel, or a cancel of the call ends the job with no file (decision 0049). An
/// export with `split` is one job for the set (decision 0067).
@MainActor
func liveExport(
    _ work: ExportWork, studio: Studio, path: String, sheetCause: @MainActor () -> AgentBusy?,
    report: @escaping @Sendable (Double) -> Void
) async throws(ToolError) -> String {
    let session = studio.session
    let source = try work.source(in: session)
    // A render writes a bad file as silence, so it reads no media state.
    if !work.isRender {
        guard let faults = await studio.exportFaults(source) else {
            throw ToolError("cannot check the audio files: the package or a file descriptor is not available.")
        }
        try work.check(faults, in: session)
        // The user can open a dialog or start an export during the media check.
        if let busy = sheetCause() { throw ToolError(busy.message(package: path)) }
    }
    if let kind = work.split {
        return try await liveSet(
            work, kind: kind, studio: studio, session: session, source: source, path: path, report: report)
    }
    // The item at `out` now is the one that `replace` confirms.
    let confirmed = work.replace ? ConfirmedFile(at: work.url) : nil
    let result: ExportResult
    do throws(StudioError) {
        result = try await studio.export(source, work.options, to: work.url, replacing: confirmed, progress: report)
    } catch .export(.cancelled) {
        // A cancel of the call task: the bridge closed, or `AgentServer` gives the server stop text.
        if Task.isCancelled { throw ToolError(cancelledMessage) }
        throw ToolError(stopMessage(studio.exportStop, noun: work.noun))
    } catch .export(let error) {
        throw ToolError(work.message(error) ?? cancelledMessage)
    } catch .exportYielded {
        throw ToolError(stopMessage(.take, noun: work.noun))
    } catch .busy {
        throw ToolError((exportBusy(studio) ?? .task).message(package: path))
    } catch {
        throw ToolError(error.message(package: path))
    }
    return try work.text(of: result, session: session, source: source)
}

/// The set of `export` with `split`. The job computes the parts and the targets on the session that it
/// renders, so `session` only feeds the confirmation of the items that `replace` takes.
@MainActor
private func liveSet(
    _ work: ExportWork, kind: SplitKind, studio: Studio, session: Session, source: ExportSource, path: String,
    report: @escaping @Sendable (Double) -> Void
) async throws(ToolError) -> String {
    let replacing: [URL: ConfirmedFile]
    do throws(SplitRefusal) { replacing = try await confirmations(work, session, source, kind) } catch {
        throw ToolError(error.message)
    }
    let result: ExportPartsResult
    do throws(StudioError) {
        result = try await studio.export(
            source, by: kind, options: work.options, folder: work.folder, stem: work.stem, replacing: replacing,
            progress: report)
    } catch .exportParts(.stopped(let stop)) {
        if Task.isCancelled { throw ToolError(cancelledMessage) }
        throw ToolError(setStopMessage(work, stop, cause: studio.exportStop))
    } catch .exportParts(let error) {
        throw ToolError(work.setRefusal(error))
    } catch .busy {
        throw ToolError((exportBusy(studio) ?? .task).message(package: path))
    } catch {
        throw ToolError(error.message(package: path))
    }
    let old = await oldFiles(work, besides: result.files)
    do throws(SetFaults) {
        let (stdout, stderr) = try work.setLines(of: result, session: session, source: source, old: old)
        return (stdout + stderr).joined(separator: "\n")
    } catch {
        throw ToolError(error.text)
    }
}

/// The text of a set that stopped. A failure gives the lines of the files on disk, the error, and the
/// stop line, as on the files. A stop of the app gives the lines of the files on disk and the cause
/// with the counts, so the agent does not try again before it asks the user.
private func setStopMessage(_ work: ExportWork, _ stop: ExportPartsStop, cause: ExportStop?) -> String {
    guard stop.error == .cancelled else { return work.stopText(stop) }
    let sentence = stopMessage(cause, noun: work.noun, nothing: ExportText.stopCounts(stop))
    return (stop.written.map(ExportText.partLine) + [sentence]).joined(separator: "\n")
}

/// The check of the targets of a set off the main actor: an lstat for each file is file I/O.
@concurrent private func confirmations(
    _ work: ExportWork, _ session: Session, _ source: ExportSource, _ kind: SplitKind
) async throws(SplitRefusal) -> [URL: ConfirmedFile] {
    try work.splitConfirmations(session, source: source, by: kind)
}

/// The folder read for the older files of the stem, off the main actor.
@concurrent private func oldFiles(_ work: ExportWork, besides files: [ExportedPart]) async -> [URL] {
    work.oldFiles(besides: files)
}
