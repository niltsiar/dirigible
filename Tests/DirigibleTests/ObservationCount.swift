import Testing

/// The registrations of the observation registrar of one `@Observable` object: the next
/// registration id, the live registrations, and the live ids of each key path.
struct Registrations {
    let next: Int
    let live: Int
    let ids: [AnyKeyPath: Set<Int>]

    /// The live registrations with an id from `since` on, by key path, with no zero count.
    func made(since: Int) -> [AnyKeyPath: Int] {
        ids.compactMapValues { ids in
            let count = ids.count { $0 >= since }
            return count > 0 ? count : nil
        }
    }
}

/// The start of each issue of a registrar read: the layout of `ObservationRegistrar.State` (`id`,
/// `observations`, `lookups`) is a detail of the runtime, not an API.
let unknownRegistrarLayout = "registrar layout of macOS 15.8 (Swift 6.2.4 runtime) not found"

/// Reads the registrar of `object` through Mirror and raw loads. On another layout it records
/// an issue and gives nil: it loads the `lookups` dictionary only after the plain counts pass.
@MainActor func registrations(of object: AnyObject, sourceLocation: SourceLocation = #_sourceLocation)
    -> Registrations?
{
    var value: Any = object
    for label in ["_$observationRegistrar", "extent", "context", "state", "buffer"] {
        guard let child = Mirror(reflecting: value).children.first(where: { $0.label == label }) else {
            Issue.record("\(unknownRegistrarLayout): no \(label)", sourceLocation: sourceLocation)
            return nil
        }
        value = child.value
    }
    guard Mirror(reflecting: value).displayStyle == .class else {
        Issue.record("\(unknownRegistrarLayout): the buffer is not a class", sourceLocation: sourceLocation)
        return nil
    }
    let buffer = value as AnyObject
    return withExtendedLifetime(buffer) {
        // The header of the managed buffer follows the object header (16 bytes).
        let header = UnsafeRawPointer(Unmanaged.passUnretained(buffer).toOpaque()) + 16
        let storage = header.load(fromByteOffset: 8, as: UInt.self)
        guard let observations = UnsafeRawPointer(bitPattern: storage), storage % 8 == 0 else {
            Issue.record("\(unknownRegistrarLayout): observations at \(storage)", sourceLocation: sourceLocation)
            return nil
        }
        guard
            let counts = plainCounts(
                id: header.load(as: Int.self), observations: observations.load(fromByteOffset: 16, as: Int.self),
                sourceLocation: sourceLocation)
        else { return nil }
        let lookups = header.load(fromByteOffset: 16, as: [AnyKeyPath: Set<Int>].self)
        return Registrations(next: counts.next, live: counts.live, ids: lookups)
    }
}

/// The next id and the live count of a registrar, or nil with an issue for values that cannot
/// be true: a negative value, or more live registrations than ids.
func plainCounts(id: Int, observations: Int, sourceLocation: SourceLocation = #_sourceLocation)
    -> (next: Int, live: Int)?
{
    guard id >= 0, observations >= 0, observations <= id else {
        Issue.record(
            "\(unknownRegistrarLayout): id \(id), observations \(observations)", sourceLocation: sourceLocation)
        return nil
    }
    return (id, observations)
}
