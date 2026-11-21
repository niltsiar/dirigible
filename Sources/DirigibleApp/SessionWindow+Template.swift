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
    /// Replace refuses an old template that a window or another process holds, and moves it to the Trash only
    /// after the new one is saved. The step is `.choosing` while a sheet shows, so no export or second sheet
    /// starts. A cancel and a stop of the job show no alert; a failure shows its alert.
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
        var old: PackageLock?
        if await prepareTemplates(folder: folder, target: target, exists: app.exists) {
            let replace = await withCheckedContinuation { (next: CheckedContinuation<Bool, Never>) in
                panels.confirmReplace(window, name.text) { next.resume(returning: $0) }
            }
            guard replace else { return }
            do throws(SessionFileError) {
                let (key, lock) = try await lockOldTemplate(target)
                // A window that still opens the package has its key and no lock yet.
                guard app.windows[key] == nil, app.studio(of: lock.identity) == nil else {
                    alert = .templateOpen(name.text)
                    return
                }
                old = lock
            } catch .locked {
                alert = .templateOpen(name.text)
                return
            } catch {
                alert = .error(.file(error))
                return
            }
        }
        exportStep = nil
        savesTemplate = true
        defer { savesTemplate = false }
        do throws(StudioError) {
            if let old {
                try await replace(target, holding: old, name: name.text, studio: studio, trash: panels.trash)
            } else {
                try await studio.saveTemplate(to: target)
            }
        } catch .template(.cancelled) {
        } catch {
            alert = .error(error)
        }
    }

    /// The save of a Replace into a folder on the volume of `target`, then `swapTemplate`.
    private func replace(
        _ target: URL, holding lock: PackageLock, name: String, studio: Studio,
        trash: @escaping @Sendable (URL) throws -> Void
    ) async throws(StudioError) {
        let folder: URL
        do { folder = try await replacementFolder(for: target) } catch { throw .template(error) }
        let saved = folder.appending(path: target.lastPathComponent)
        do { try await studio.saveTemplate(to: saved) } catch {
            await removeItem(folder)
            throw error
        }
        switch await swapTemplate(target, with: saved, holding: lock, trash: trash) {
        case .replaced: break
        case .trashFailed: alert = .templateTrash(name)
        case .failed(let code): throw .template(.publish(.writeFailed(step: "rename", errno: code)))
        }
    }
}
