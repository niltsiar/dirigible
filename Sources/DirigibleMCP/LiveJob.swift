import DirigibleAudio
import DirigibleCore
import Foundation

/// Runs one long agent call on the studio of an open window (decision 0049). The job reports its
/// fraction through `report`, and a cancel of the call task stops it. A busy target refuses, as
/// in `liveCall`.
@MainActor
func liveJob(_ call: AgentCall, target: AgentTarget, report: @escaping @Sendable (Double) -> Void) async
    -> AgentReply
{
    if let busy = target.busy { return .result(text: busy.message(package: call.path), isError: true) }
    let studio = target.studio
    switch call.work {
    case .loudness(let ids):
        let clips: [Clip]
        do throws(SessionError) { clips = try loudnessClips(ids, in: studio.session) } catch {
            return .result(text: error.message, isError: true)
        }
        do throws(POSIXError) {
            let measured = try await studio.measureLoudness(clips, progress: report)
            return .result(text: zip(clips, measured).map(loudnessLine).joined(separator: "\n"), isError: false)
        } catch {
            return .result(text: error.code == .ECANCELED ? cancelledMessage : audioReadMessage(error), isError: true)
        }
    case .export(let work):
        // A running export shows its sheet too: its cause comes first.
        if let busy = exportBusy(studio) { return .result(text: busy.message(package: call.path), isError: true) }
        if target.dialog() { return .result(text: AgentBusy.dialog.message(package: call.path), isError: true) }
        do throws(ToolError) {
            return .result(
                text: try await liveExport(
                    work, studio: studio, path: call.path, dialog: target.dialog, report: report),
                isError: false)
        } catch {
            return .result(text: error.message, isError: true)
        }
    case .level(let work):
        return await liveLevel(work, studio: studio, call: call, report: report)
    case .importFile(let work):
        return await liveImport(work, studio: studio, call: call, report: report)
    case .chapters(let work):
        if let busy = exportBusy(studio) { return .result(text: busy.message(package: call.path), isError: true) }
        if target.dialog() { return .result(text: AgentBusy.dialog.message(package: call.path), isError: true) }
        do throws(ToolError) {
            return .result(text: try await liveChapters(work, studio: studio), isError: false)
        } catch {
            return .result(text: error.message, isError: true)
        }
    // `AgentServer` sends only long work here.
    case .edit, .info, .create, .paste, .backups, .revert, .episode, .marker, .episodeInfo, .prune, .record, .words:
        return .notOpen
    }
}

/// `level` through `Studio.level`: one undo step with the agent name. The banner Cancel or a
/// cancel of the call ends it with no gain change (decision 0049).
@MainActor
private func liveLevel(
    _ work: LevelWork, studio: Studio, call: AgentCall, report: @escaping @Sendable (Double) -> Void
) async -> AgentReply {
    let ids: [ClipID]
    do throws(SessionError) { ids = try work.chosen(in: studio.session) } catch {
        return .result(text: error.message, isError: true)
    }
    do throws(StudioError) {
        let (summary, levels) = try await studio.level(Set(ids), work.mode, agent: call.agent, progress: report)
        let text = (LevelWork.lines(ids, levels) + [LevelWork.text(of: summary)]).joined(separator: "\n")
        return .result(text: text, isError: false)
    } catch .levelCancelled {
        // A cancel of the call task: the bridge closed, or `AgentServer` gives the server stop text.
        let text = Task.isCancelled ? cancelledMessage : "The user cancelled the level in Dirigible. No gain changed."
        return .result(text: text, isError: true)
    } catch .busy {
        return .result(text: AgentBusy.task.message(package: call.path), isError: true)
    } catch {
        return .result(text: error.message(package: call.path), isError: true)
    }
}

/// `export` and `render` through `Studio.export`: the window shows the export sheet, and a take
/// start, the sheet Cancel, or a cancel of the call ends the job with no file (decision 0049).
@MainActor
private func liveExport(
    _ work: ExportWork, studio: Studio, path: String, dialog: @MainActor () -> Bool,
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
        // The user can open a dialog during the media check.
        if dialog() { throw ToolError(AgentBusy.dialog.message(package: path)) }
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

/// `import` through `Studio.importAudio`: one undo step with the agent name. The banner Cancel or
/// a cancel of the call ends it with no clip and no new WAV (decision 0049).
@MainActor
private func liveImport(
    _ work: ImportWork, studio: Studio, call: AgentCall, report: @escaping @Sendable (Double) -> Void
) async -> AgentReply {
    do throws(StudioError) {
        let clip = try await studio.importAudio(
            work.url, to: work.target, level: work.level, agent: call.agent, progress: report)
        return .result(text: clip.rawValue, isError: false)
    } catch .audioImport(.cancelled) {
        // A cancel of the call task: the bridge closed, or `AgentServer` gives the server stop text.
        let text = Task.isCancelled ? cancelledMessage : stopMessage(studio.importStop, noun: "import", nothing: noClip)
        return .result(text: text, isError: true)
    } catch .importYielded {
        return .result(text: stopMessage(.take, noun: "import", nothing: noClip), isError: true)
    } catch .audioImport(let error) {
        return .result(text: ImportWork.message(error, file: work.file, package: call.path), isError: true)
    } catch .busy {
        let busy: AgentBusy = studio.pendingTake != nil ? .pendingTake : .task
        return .result(text: busy.message(package: call.path), isError: true)
    } catch {
        return .result(text: error.message(package: call.path), isError: true)
    }
}

/// `chapters_export` through `Studio.exportChapters`: the session of the window, written off the
/// main actor. It has no progress and no cancel: the job writes a small file and its images.
@MainActor
private func liveChapters(_ work: ChaptersWork, studio: Studio) async throws(ToolError) -> String {
    let session = studio.session
    let source: ChaptersWork.Source
    do throws(ChaptersWork.Refusal) { source = try work.source(in: session) } catch { throw ToolError(error.text) }
    try await checkTarget(work)
    do throws(ExportError) {
        try await studio.exportChapters(
            session, in: source.range, to: work.url, form: work.form, replacingImages: work.replace)
    } catch {
        throw ToolError(work.message(error))
    }
    return ChaptersWork.text(of: source)
}

/// The target check of a chapters export off the main actor: an lstat is file I/O.
@concurrent private func checkTarget(_ work: ChaptersWork) async throws(ToolError) { try work.checkTarget() }

private let noClip = "No clip was added."

/// The text of an export or an import that the app stopped: the agent must not try again before
/// it asks the user.
private func stopMessage(_ stop: ExportStop?, noun: String, nothing: String = "No file was written.") -> String {
    switch stop {
    case .user: "The user cancelled the \(noun) in Dirigible. \(nothing)"
    case .take: "A take started in Dirigible, so the \(noun) stopped. \(nothing)"
    case .close, nil: "The session window closed, so the \(noun) stopped. \(nothing)"
    }
}

/// The text of a long call that a stop of the agent server ended: the user turned the server off,
/// or quits.
func serverStopMessage(_ work: ToolWork) -> String {
    switch work {
    case .export(let export):
        "Dirigible stopped its agent server, so the \(export.noun) stopped. No file was written."
    case .level: "Dirigible stopped its agent server, so the level stopped. No gain changed."
    case .importFile: "Dirigible stopped its agent server, so the import stopped. No clip was added."
    case .loudness: "Dirigible stopped its agent server, so the loudness measure stopped."
    // `AgentServer` gives this text only for long work, and a chapters export does not cancel.
    case .chapters, .edit, .info, .create, .paste, .backups, .revert, .episode, .marker, .episodeInfo, .prune, .record,
        .words:
        "Dirigible stopped its agent server, so the call stopped."
    }
}

/// The busy cause of an export that `Studio.export` refuses: a running export or a take that is
/// not finalized.
@MainActor
private func exportBusy(_ studio: Studio) -> AgentBusy? {
    studio.exportProgress != nil ? .export : studio.pendingTake != nil ? .pendingTake : nil
}
