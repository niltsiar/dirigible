import DirigibleCore

extension Studio {
    /// The clipboard of the bin item `item` (F22): its excerpt with the pool records of now
    /// (`Session.excerpt(of:)`), of this package. A paste of it is a paste of a Copy: `pasteInPlace`,
    /// else `pasteAcross`. Each bin edit is a session edit through `edit`, one undo entry.
    public func clipboard(of item: BinItemID) throws(StudioError) -> Clipboard {
        do throws(SessionError) {
            return clipboard(of: try session.excerpt(of: item))
        } catch {
            throw .session(error)
        }
    }
}
