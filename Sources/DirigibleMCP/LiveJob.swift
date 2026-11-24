import DirigibleAudio
import DirigibleCore
import Foundation

/// Runs one long agent call on the studio of an open window (decision 0049). The job reports its
/// fraction through `report`, and a cancel of the call task stops it. A busy target refuses, as
/// in `liveCall`. Each other target saves its typed values first.
@MainActor
func liveJob(_ call: AgentCall, target: AgentTarget, report: @escaping @Sendable (Double) -> Void) async
    -> AgentReply
{
    if let busy = target.busy { return .result(text: busy.message(package: call.path), isError: true) }
    target.commit()
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
        if let busy = target.sheetCause() { return .result(text: busy.message(package: call.path), isError: true) }
        do throws(ToolError) {
            return .result(
                text: try await liveExport(
                    work, studio: studio, path: call.path, sheetCause: target.sheetCause, report: report),
                isError: false)
        } catch {
            return .result(text: error.message, isError: true)
        }
    case .level(let work):
        return await liveLevel(work, studio: studio, call: call, report: report)
    case .duck(let work):
        return await liveDuck(work, studio: studio, call: call, report: report)
    case .ride(let work):
        return await liveRide(work, studio: studio, call: call, report: report)
    case .sync(let work):
        return await liveSync(work, studio: studio, call: call, report: report)
    case .matchVoice(let work, let request):
        return await liveMatchVoice(work, request, studio: studio, call: call, report: report)
    case .importFile(let work):
        return await liveImport(work, studio: studio, call: call, report: report)
    case .importSession(let work):
        return await liveImportSession(work, studio: studio, call: call, report: report)
    case .splitStereo(let work):
        return await liveSplit(work, studio: studio, call: call, report: report)
    case .clipRender(let work):
        return await liveDenoise(work, studio: studio, call: call, report: report)
    case .chapters(let work):
        if let busy = exportBusy(studio) { return .result(text: busy.message(package: call.path), isError: true) }
        if let busy = target.sheetCause() { return .result(text: busy.message(package: call.path), isError: true) }
        do throws(ToolError) {
            return .result(text: try await liveChapters(work, studio: studio), isError: false)
        } catch {
            return .result(text: error.message, isError: true)
        }
    case .transcriptExport(let work):
        if let busy = exportBusy(studio) { return .result(text: busy.message(package: call.path), isError: true) }
        if let busy = target.sheetCause() { return .result(text: busy.message(package: call.path), isError: true) }
        do throws(ToolError) {
            return .result(text: try await liveTranscriptExport(work, studio: studio), isError: false)
        } catch {
            return .result(text: error.message, isError: true)
        }
    case .read(let work):
        return await liveRead(work, studio: studio, call: call, report: report)
    case .transcribe(let work):
        return await liveTranscribe(work, studio: studio, call: call, report: report)
    case .stems(let work):
        return await liveStems(work, target: target, path: call.path, report: report)
    // `AgentServer` sends only long work here.
    case .edit, .takeImport, .info, .create, .paste, .favorite, .backups, .bins, .revert, .episode, .marker,
        .episodeInfo, .prune, .archive, .record, .transport, .words,
        .takeMap, .batch:
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

/// `duck` through `Studio.duck`: one undo step with the agent name. The banner Cancel or a cancel
/// of the call ends it with no envelope change (decisions 0049 and 0060).
@MainActor
private func liveDuck(
    _ work: DuckWork, studio: Studio, call: AgentCall, report: @escaping @Sendable (Double) -> Void
) async -> AgentReply {
    let planned: (speech: [TrackID], music: [TrackID], scope: Range<Frames>, shape: DuckShape)
    do throws(SessionError) { planned = try work.plan(in: studio.session) } catch {
        return .result(text: error.message, isError: true)
    }
    do throws(StudioError) {
        let result = try await studio.duck(
            speech: planned.speech, music: planned.music, range: work.range, shape: planned.shape, agent: call.agent,
            progress: report)
        return .result(
            text: (DuckWork.lines(result) + [DuckWork.text(of: result)]).joined(separator: "\n"), isError: false)
    } catch .duckCancelled {
        // A cancel of the call task: the bridge closed, or `AgentServer` gives the server stop text.
        let text =
            Task.isCancelled ? cancelledMessage : "The user cancelled the duck in Dirigible. No envelope changed."
        return .result(text: text, isError: true)
    } catch .busy {
        return .result(text: AgentBusy.task.message(package: call.path), isError: true)
    } catch {
        return .result(text: error.message(package: call.path), isError: true)
    }
}

/// `clip_level_over_time` through `Studio.levelOverTime`, or with `clear`
/// `Studio.removeLevelOverTime`: one undo step with the agent name. The banner Cancel or a cancel
/// of the call ends it with no ride change (decisions 0049 and 0060).
@MainActor
private func liveRide(
    _ work: RideWork, studio: Studio, call: AgentCall, report: @escaping @Sendable (Double) -> Void
) async -> AgentReply {
    do throws(StudioError) {
        let clips = Set(work.clips)
        var changed: [ClipID] = []
        if work.clear {
            changed = try studio.removeLevelOverTime(clips, in: work.range, agent: call.agent)
        } else {
            _ = try await studio.levelOverTime(clips, agent: call.agent, progress: report)
        }
        return .result(text: work.lines(changed: changed, in: studio.session).joined(separator: "\n"), isError: false)
    } catch .rideCancelled {
        // A cancel of the call task: the bridge closed, or `AgentServer` gives the server stop text.
        let text =
            Task.isCancelled
            ? cancelledMessage : "The user cancelled the level over time in Dirigible. No ride changed."
        return .result(text: text, isError: true)
    } catch .busy {
        return .result(text: AgentBusy.task.message(package: call.path), isError: true)
    } catch {
        return .result(text: error.message(package: call.path), isError: true)
    }
}

/// `track_match_voice` with `reference` through `Studio.matchVoice`: one undo step with the agent name.
/// The banner Cancel or a cancel of the call ends it with no track changed (decisions 0049 and 0074).
@MainActor
private func liveMatchVoice(
    _ work: MatchWork, _ request: MatchWork.Request, studio: Studio, call: AgentCall,
    report: @escaping @Sendable (Double) -> Void
) async -> AgentReply {
    do throws(StudioError) {
        let matches = try await studio.matchVoice(
            reference: request.reference, range: request.range, tracks: Set(work.tracks), amount: request.amount,
            agent: call.agent, progress: report)
        return .result(
            text: work.lines(matched: Set(matches.keys), in: studio.session).joined(separator: "\n"), isError: false)
    } catch .matchCancelled {
        // A cancel of the call task: the bridge closed, or `AgentServer` gives the server stop text.
        let text =
            Task.isCancelled ? cancelledMessage : "The user cancelled the voice match in Dirigible. No track changed."
        return .result(text: text, isError: true)
    } catch .busy {
        return .result(text: AgentBusy.task.message(package: call.path), isError: true)
    } catch {
        return .result(text: error.message(package: call.path), isError: true)
    }
}

/// `silences`, `nearest_pause`, and `meter` through `Studio.readMix`: the session of the window
/// (decision 0062). A take start, the close of the window, or a cancel of the call ends the read.
@MainActor
private func liveRead(
    _ work: ReadWork, studio: Studio, call: AgentCall, report: @escaping @Sendable (Double) -> Void
) async -> AgentReply {
    let result: Result<ReadOutput, ReadFailure>
    do throws(StudioError) {
        result = try await studio.readMix(progress: report) { session, package, progress, isCancelled in
            Result { () throws(ReadFailure) in
                try work.read(session, package: package, progress: progress, isCancelled: isCancelled)
            }
        }
    } catch .readYielded {
        return .result(text: "Dirigible started a take, so the read stopped.", isError: true)
    } catch .readClosed {
        return .result(text: "The session window closed, so the read stopped.", isError: true)
    } catch .busy {
        return .result(text: AgentBusy.task.message(package: call.path), isError: true)
    } catch {
        return .result(text: error.message(package: call.path), isError: true)
    }
    switch result {
    case .success(let output): return .result(text: output.text, isError: false)
    case .failure(let error): return .result(text: error.message, isError: true)
    }
}

/// `import` through `Studio.importAudio`: one undo step with the agent name. The banner Cancel or
/// a cancel of the call ends it with no clip and no new WAV (decision 0049).
@MainActor
private func liveImport(
    _ work: ImportWork, studio: Studio, call: AgentCall, report: @escaping @Sendable (Double) -> Void
) async -> AgentReply {
    let revision = studio.sessionRevision
    do throws(StudioError) {
        let clip = try await studio.importAudio(
            work.url, to: work.target, level: work.level, agent: call.agent, progress: report)
        let note = TakeWork.note(studio, after: revision, agent: call.agent)
        return .result(text: ([clip.rawValue] + note).joined(separator: "\n"), isError: false)
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

/// `clip_split_stereo` through `Studio.splitStereo`: one undo step with the agent name, and the tracks
/// "<name> L" and "<name> R". The banner Cancel or a cancel of the call ends it with no track and no new
/// WAV (decision 0049).
@MainActor
private func liveSplit(
    _ work: SplitWork, studio: Studio, call: AgentCall, report: @escaping @Sendable (Double) -> Void
) async -> AgentReply {
    let revision = studio.sessionRevision
    do throws(StudioError) {
        let parts = try await studio.splitStereo(
            work.clips, names: SplitWork.names, agent: call.agent, progress: report)
        let note = TakeWork.note(studio, after: revision, agent: call.agent)
        return .result(text: (SplitWork.lines(parts) + note).joined(separator: "\n"), isError: false)
    } catch .split(.cancelled) {
        // A cancel of the call task: the bridge closed, or `AgentServer` gives the server stop text.
        let text = Task.isCancelled ? cancelledMessage : stopMessage(studio.importStop, noun: "split", nothing: noTrack)
        return .result(text: text, isError: true)
    } catch .splitYielded {
        return .result(text: stopMessage(.take, noun: "split", nothing: noTrack), isError: true)
    } catch .busy {
        let busy: AgentBusy = studio.pendingTake != nil ? .pendingTake : .task
        return .result(text: busy.message(package: call.path), isError: true)
    } catch {
        return .result(text: error.message(package: call.path), isError: true)
    }
}

/// `clip_denoise` and `clip_repair` through `Studio.renderClips`: one undo step with the agent name,
/// and the clips on the new files. The banner Cancel or a cancel of the call ends it with no clip
/// changed and no new WAV (decision 0049).
@MainActor
private func liveDenoise(
    _ work: ClipRenderWork, studio: Studio, call: AgentCall, report: @escaping @Sendable (Double) -> Void
) async -> AgentReply {
    let revision = studio.sessionRevision
    do throws(StudioError) {
        let rendered = try await studio.renderClips(
            work.clips, request: work.request, agent: call.agent, progress: report)
        let note = TakeWork.note(studio, after: revision, agent: call.agent)
        return .result(
            text: (ClipRenderWork.lines(rendered.clips, repairs: rendered.repairs) + note).joined(separator: "\n"),
            isError: false)
    } catch .clipRender(.cancelled) {
        // A cancel of the call task: the bridge closed, or `AgentServer` gives the server stop text.
        let text =
            Task.isCancelled
            ? cancelledMessage : stopMessage(studio.importStop, noun: work.noun, nothing: noChange)
        return .result(text: text, isError: true)
    } catch .clipRenderYielded {
        return .result(text: stopMessage(.take, noun: work.noun, nothing: noChange), isError: true)
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

/// `transcript_export` for the session of the window: the text from the session now, the check and the
/// write off the main actor. It has no progress and no cancel: the file is small.
@MainActor
private func liveTranscriptExport(_ work: TranscriptExportWork, studio: Studio) async throws(ToolError) -> String {
    let (text, warnings) = try work.render(studio.session)
    try await write(text, work)
    return TranscriptExportWork.text(of: warnings)
}

/// The target check and the write of a transcript export off the main actor: both are file I/O.
@concurrent private func write(_ text: String, _ work: TranscriptExportWork) async throws(ToolError) {
    try work.checkTarget()
    try work.write(text)
}

/// The target check of a chapters export off the main actor: an lstat is file I/O.
@concurrent private func checkTarget(_ work: ChaptersWork) async throws(ToolError) { try work.checkTarget() }

private let noClip = "No clip was added."
let noTrack = "No track was added."
private let noChange = "No clip changed."

/// The text of an export, an import, or a split that the app stopped: the agent must not try again before
/// it asks the user.
func stopMessage(_ stop: ExportStop?, noun: String, nothing: String = "No file was written.") -> String {
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
    case .export(let export) where export.split != nil || !export.presets.isEmpty:
        "Dirigible stopped its agent server, so the export stopped. The files that were written before the stop "
            + "stay in \(export.folder.path)."
    case .export(let export):
        "Dirigible stopped its agent server, so the \(export.noun) stopped. No file was written."
    case .stems: "Dirigible stopped its agent server, so the stem export stopped. No stem was written."
    case .level: "Dirigible stopped its agent server, so the level stopped. No gain changed."
    case .duck: "Dirigible stopped its agent server, so the duck stopped. No envelope changed."
    case .ride: "Dirigible stopped its agent server, so the level over time stopped. No ride changed."
    case .sync: "Dirigible stopped its agent server, so the sync stopped. No clip moved."
    case .matchVoice: "Dirigible stopped its agent server, so the voice match stopped. No track changed."
    case .importFile: "Dirigible stopped its agent server, so the import stopped. No clip was added."
    case .importSession: "Dirigible stopped its agent server, so the session import stopped. No track was added."
    case .splitStereo: "Dirigible stopped its agent server, so the split stopped. No track was added."
    case .clipRender(let render): "Dirigible stopped its agent server, so the \(render.noun) stopped. No clip changed."
    case .loudness: "Dirigible stopped its agent server, so the loudness measure stopped."
    // `AgentServer` gives this text only for long work, and a chapters export does not cancel.
    case .read: "Dirigible stopped its agent server, so the read stopped."
    case .transcribe: "Dirigible stopped its agent server, so the transcription stopped. No words were added."
    case .chapters, .transcriptExport, .edit, .takeImport, .info, .create, .paste, .favorite, .backups, .bins,
        .revert, .episode, .marker,
        .episodeInfo,
        .prune, .archive, .record, .transport,
        .words, .takeMap, .batch:
        "Dirigible stopped its agent server, so the call stopped."
    }
}

/// The busy cause of an export that `Studio.export` refuses: a running export or a take that is
/// not finalized.
@MainActor
func exportBusy(_ studio: Studio) -> AgentBusy? {
    studio.exportProgress != nil ? .export : studio.pendingTake != nil ? .pendingTake : nil
}
