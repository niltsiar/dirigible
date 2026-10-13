import DirigibleCore
import Foundation
import os

extension Studio {
    /// The loudness of each clip of `clips` in the session of now, for an agent `loudness`
    /// (decision 0049): an edit does not wait for its autosave, so the files can lag the window.
    /// It measures on a utility GCD thread, in the package that the lock holds now. A cancel of
    /// the caller stops it at the next block: then it throws ECANCELED. `progress` gets the
    /// fraction of all clips on the main actor.
    public func measureLoudness(
        _ clips: [Clip], progress: @escaping @MainActor @Sendable (Double) -> Void = { _ in }
    ) async throws(POSIXError) -> [(loudness: Loudness, fault: MediaFault?)] {
        let (session, lock, step) = (session, lock, environment.loudnessBlock)
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        let hop: @Sendable (Double) -> Void = { fraction in Task { @MainActor in progress(fraction) } }
        // On a GCD thread `Task.isCancelled` is false, so a cancel of the caller sets a flag that
        // the measure reads at each block, as `exportTask`.
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(
                        returning: Result { () throws(POSIXError) in
                            let package: URL
                            // A package that left its volume reads as a missing folder.
                            do { package = try lock.package() } catch { throw POSIXError(.ENOENT) }
                            return try clipsLoudness(
                                clips, in: session, package: package, progress: hop,
                                isCancelled: {
                                    step()
                                    return cancelled.withLock { $0 }
                                })
                        })
                }
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
        return try result.get()
    }
}
