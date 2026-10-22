import DirigibleCore
import Foundation

extension Studio {
    /// The take map of the session (decision 0061), or the anchor read fault. It uses the anchors
    /// of the open and of the last take outcome, so a read reads no file.
    public var takeMap: Result<TakeMap, FinalizeError> { TakeMap.of(session, anchors: takeAnchors) }

    /// The anchor read fault that keeps the take map from the session, or nil.
    public var takeSyncFault: FinalizeError? {
        if case .failure(let error) = takeMap { error } else { nil }
    }
}
