import DirigibleAudio

extension ChromeState {
    /// The report banners, in order. Each report shows only while the session is at the revision
    /// of its stamp, so the next change of the session hides it.
    @MainActor static func reportBanners(_ model: SessionWindow, _ studio: Studio) -> [WindowBanner] {
        var banners: [WindowBanner] = []
        if let shown = model.exportReport, shown.revision == studio.sessionRevision {
            banners.append(.exportReport(shown.report, file: shown.file))
        }
        if let shown = model.chapterWarnings, shown.revision == studio.sessionRevision {
            if !shown.names.isEmpty { banners.append(.chaptersDropped(shown.names, file: shown.file)) }
            if shown.imagesOmitted { banners.append(.chapterImagesOmitted(file: shown.file)) }
            if shown.titleMissing { banners.append(.titleMissing(file: shown.file)) }
        }
        if let shown = model.transcriptLeftOut, shown.revision == studio.sessionRevision {
            banners.append(.transcriptLeftOut(count: shown.count, file: shown.file))
        }
        if let shown = model.transcriptFollow.importReport, shown.revision == studio.sessionRevision {
            banners.append(.transcriptImported(shown.text, press: shown.press))
        }
        if let shown = model.levelReport, shown.revision == studio.sessionRevision {
            banners.append(.levelReport(shown.report, press: shown.press))
        }
        if let shown = model.denoiseReport, shown.revision == studio.sessionRevision {
            banners.append(.noiseReduced(clips: shown.clips, treatment: shown.treatment, press: shown.press))
        }
        if let shown = model.repairReport, shown.revision == studio.sessionRevision {
            banners.append(.soundRepaired(shown.result, press: shown.press))
        }
        if let shown = model.duckReport, shown.revision == studio.sessionRevision { banners.append(shown.banner) }
        if let shown = model.pruneReport, shown.revision == studio.sessionRevision {
            let moved = shown.report.moved.map(\.item.bytes)
            banners.append(.unusedFilesMoved(count: moved.count, bytes: moved.reduce(0, +)))
            if !shown.report.failed.isEmpty { banners.append(.unusedFilesFailed(shown.report.failed.map(\.item.path))) }
        }
        switch model.transcribe.notice {
        case .stopped(let request, let revision, let press) where revision == studio.sessionRevision:
            banners.append(.transcriptionStopped(request, press: press))
        case .noWords(let revision, let press) where revision == studio.sessionRevision:
            banners.append(.noWordsFound(press: press))
        default: break
        }
        if let shown = model.consentExpired, shown.revision == studio.sessionRevision {
            banners.append(.consentExpired(agent: shown.agent))
        }
        // One row for each take that a revision of an agent moved from in sync to broken
        // (decision 0061): a user edit, an undo, and a take outcome have no agent.
        let change = studio.takeSyncChange
        if change.revision == studio.sessionRevision, let agent = change.agent {
            for item in change.changes {
                guard case .inSync = item.old, case .broken(let from, _) = item.new else { continue }
                banners.append(
                    .takeSyncBroken(
                        take: item.take, from: from, rate: studio.session.sampleRate, agent: agent.name,
                        revision: change.revision))
            }
        }
        return banners
    }
}
