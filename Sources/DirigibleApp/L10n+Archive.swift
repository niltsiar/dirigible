import DirigibleAudio
import DirigibleCore
import Foundation

/// The texts of the package job faults (decision 0072). The switches have no `default`.
extension L10n {
    static func message(for fault: ArchiveFault) -> String {
        switch fault {
        case .space(let need, let free): errorArchiveSpace.format(bytes(need), bytes(free))
        case .clip(.read(let file, let code)), .clip(.write(let file, let code)):
            errorArchiveClip.format(file, Int(code))
        case .clip(.notArchivable(let path)), .clip(.nameTaken(let path)), .clip(.mismatch(let path)):
            errorArchiveClipOther.format(path)
        case .favoritesStore: errorArchiveStore.text
        case .file(let error): message(for: error)
        // A store write refuses a pending take before its step, and a step has no Cancel.
        case .pendingTake, .cancelled: errorSessionOther.text
        }
    }
}
