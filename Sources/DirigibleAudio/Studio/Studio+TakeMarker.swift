import DirigibleCore

extension Studio {
    /// True while a take records and no settle runs (F107): the one rule of the take entry and of
    /// the Add Marker and Add Chapter items during a take.
    public var canAddTakeMarker: Bool {
        guard case .recording = transport else { return false }
        return !settling
    }

    /// Adds a marker or a chapter at the record head while a take records (F107), as one undo
    /// entry, and saves the session with its `<recording>`. Throws `.busy` when
    /// `canAddTakeMarker` is false.
    public func addMarkerAtRecordHead(_ kind: Marker.Kind, name: String) throws(StudioError) -> Marker {
        try addMarkerAtRecordHead(kind, name: name, atHostNanos: hostNanosNow())
    }

    /// `addMarkerAtRecordHead(_:name:)` at host time `time`. Tests pin the position with it.
    func addMarkerAtRecordHead(_ kind: Marker.Kind, name: String, atHostNanos time: UInt64) throws(StudioError)
        -> Marker
    {
        guard canAddTakeMarker, let head = liveHead(atHostNanos: time) else { throw .busy }
        let marker = Marker(id: MarkerID(), name: name, position: head, kind: kind)
        do throws(SessionError) {
            try recordEdit(agent: nil) { session throws(SessionError) in try session.setMarker(marker) }
        } catch { throw .session(error) }
        return marker
    }
}
