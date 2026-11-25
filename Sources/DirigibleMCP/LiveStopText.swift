import DirigibleAudio

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
