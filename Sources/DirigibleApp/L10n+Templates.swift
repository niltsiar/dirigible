import DirigibleAudio
import DirigibleCore
import Foundation

extension L10n {
    /// The text of a template copy error. `table` gives the format of a key: the tests read the tables, which
    /// `Bundle.main` lacks.
    static func message(for error: TemplateError, table: (L10n) -> String = { $0.text }) -> String {
        func fill(_ key: L10n, _ arguments: any CVarArg...) -> String {
            String(format: table(key), locale: .current, arguments: arguments)
        }
        switch error {
        case .read(let error): return message(for: error)
        case .pendingTake: return table(.errorTemplatePending)
        case .notRegularFile(let path): return fill(.errorTemplateFile, path)
        case .sourceChanged(let path): return fill(.errorTemplateChanged, path)
        case .missing(let path): return fill(.errorTemplateMissing, path)
        case .notDownloaded(let path): return fill(.errorTemplateDownload, path)
        case .space(let needed, let free): return fill(.errorTemplateSpace, bytes(needed), bytes(free))
        case .write(let file, let errno): return fill(.errorTemplateWrite, file, Int(errno))
        // The windows show no alert for a cancel.
        case .cancelled: return table(.errorSessionOther)
        case .nameTooLong: return table(.startNameErrorLong)
        case .publish(.exists): return table(.errorTemplateExists)
        case .publish(let error): return message(for: error)
        }
    }
}
