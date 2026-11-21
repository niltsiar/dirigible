import DirigibleAudio
import DirigibleCore
import Foundation

extension SessionWindow {
    /// The text of the progress sheet: the template text while this window saves a template, else the place of
    /// the file in hand for a split export, else "Exporting...".
    var sheetTitle: String {
        savesTemplate ? L10n.sheetTemplateTitle.text : exportSheetTitle(studio?.exportFile)
    }

    /// File > Save as Template... is on when an export could start and the app has a templates folder.
    var canSaveTemplate: Bool { app?.templatesFolder != nil && exportStudio != nil }

    /// File > Save as Template... (decision 0079): the name sheet with the line of what the template keeps, the
    /// Replace question for a name that exists, then `Studio.saveTemplate` into `Templates/` of the default folder.
    /// The step is `.choosing` while a sheet shows, so no export or second sheet starts. A cancel and a stop of
    /// the job show no alert; a failure shows its alert.
    func saveAsTemplate() async {
        guard canSaveTemplate, let app, let window, let studio = exportStudio, let folder = app.templatesFolder,
            let episode = try? studio.session.newEpisode()
        else { return }
        exportStep = .choosing
        defer { if exportStep == .choosing { exportStep = nil } }
        let keeps = await templateKeeps(of: episode, in: url).text()
        let panels = app.templatePanels
        let answer = await withCheckedContinuation { (next: CheckedContinuation<String?, Never>) in
            panels.chooseName(window, keeps) { next.resume(returning: $0) }
        }
        guard let answer, let name = try? SessionName(answer, limit: .template), idleStudio === studio else { return }
        let target = folder.appending(path: "\(name.text).dirigible")
        if await prepareTemplates(folder: folder, target: target, exists: app.exists) {
            let replace = await withCheckedContinuation { (next: CheckedContinuation<Bool, Never>) in
                panels.confirmReplace(window, name.text) { next.resume(returning: $0) }
            }
            guard replace else { return }
            do {
                try await moveToTrash(target, using: panels.trash)
            } catch {
                alert = .templateTrash(name.text)
                return
            }
        }
        exportStep = nil
        savesTemplate = true
        defer { savesTemplate = false }
        do throws(StudioError) {
            try await studio.saveTemplate(to: target)
        } catch .template(.cancelled) {
        } catch {
            alert = .error(error)
        }
    }
}
