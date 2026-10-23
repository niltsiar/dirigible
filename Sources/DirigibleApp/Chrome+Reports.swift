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
        }
        if let shown = model.levelReport, shown.revision == studio.sessionRevision {
            banners.append(.levelReport(shown.report, press: shown.press))
        }
        if let shown = model.duckReport, shown.revision == studio.sessionRevision { banners.append(shown.banner) }
        if let shown = model.pruneReport, shown.revision == studio.sessionRevision {
            let moved = shown.report.moved.map(\.item.bytes)
            banners.append(.unusedFilesMoved(count: moved.count, bytes: moved.reduce(0, +)))
            if !shown.report.failed.isEmpty { banners.append(.unusedFilesFailed(shown.report.failed.map(\.item.path))) }
        }
        if let shown = model.consentExpired, shown.revision == studio.sessionRevision {
            banners.append(.consentExpired(agent: shown.agent))
        }
        return banners
    }
}
