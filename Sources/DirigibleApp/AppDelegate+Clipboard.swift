import DirigibleAudio
import DirigibleCore

extension AppDelegate {
    /// The open studio of the package with `identity` (decision 0042), for the source path of a
    /// paste. Nil for a nil identity: a package with no identity never matches another one.
    func studio(of identity: PackageID?) -> Studio? {
        windows.values.lazy.compactMap(\.studio).first { PackageID.same($0.identity, identity) }
    }
}
