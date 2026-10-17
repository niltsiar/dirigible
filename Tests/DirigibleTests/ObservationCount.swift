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
/// an issue and gives nil, and never crashes: see `registrations(header:)`.
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
        registrations(
            header: UnsafeRawPointer(Unmanaged.passUnretained(buffer).toOpaque()) + 16, sourceLocation: sourceLocation)
    }
}

/// Reads the registrar state at `header`: `id` at offset 0, the `observations` storage at 8 (its
/// count at 16), and the `lookups` dictionary at 16. It dereferences a word only when the word is
/// above page zero and aligned, and loads `lookups` only when the plain counts pass and the word
/// points to dictionary storage of `[AnyKeyPath: Set<Int>]`. Else it records an issue and gives nil.
func registrations(header: UnsafeRawPointer, sourceLocation: SourceLocation = #_sourceLocation) -> Registrations? {
    guard let observations = object(header, at: 8, "observations", sourceLocation),
        let counts = plainCounts(
            id: header.load(as: Int.self), observations: observations.load(fromByteOffset: 16, as: Int.self),
            sourceLocation: sourceLocation),
        let lookups = object(header, at: 16, "lookups", sourceLocation)
    else { return nil }
    guard dictionaryClasses.contains(lookups.load(as: UInt.self)) else {
        Issue.record("\(unknownRegistrarLayout): lookups is not dictionary storage", sourceLocation: sourceLocation)
        return nil
    }
    let ids = header.load(fromByteOffset: 16, as: [AnyKeyPath: Set<Int>].self)
    return Registrations(next: counts.next, live: counts.live, ids: ids)
}

/// The word at `offset` of `header` as the address of an object, or nil with an issue. No object
/// is under the end of `__PAGEZERO` of a 64-bit macOS process (4 GiB) or off pointer alignment.
private func object(_ header: UnsafeRawPointer, at offset: Int, _ name: String, _ sourceLocation: SourceLocation)
    -> UnsafeRawPointer?
{
    let word = header.load(fromByteOffset: offset, as: UInt.self)
    guard word >= 0x1_0000_0000, word % UInt(MemoryLayout<UnsafeRawPointer>.alignment) == 0,
        let address = UnsafeRawPointer(bitPattern: word)
    else {
        Issue.record(
            "\(unknownRegistrarLayout): \(name) at 0x\(String(word, radix: 16))", sourceLocation: sourceLocation)
        return nil
    }
    return address
}

/// The class words of the storage of an empty and of a filled `[AnyKeyPath: Set<Int>]`: the
/// storage of an empty dictionary is a shared singleton of its own class.
private let dictionaryClasses: Set<UInt> = {
    func storageClass(_ dictionary: [AnyKeyPath: Set<Int>]) -> UInt {
        withExtendedLifetime(dictionary) {
            withUnsafeBytes(of: dictionary) { $0.load(as: UnsafeRawPointer.self) }.load(as: UInt.self)
        }
    }
    return [storageClass([:]), storageClass([\Registrations.next: [0]])]
}()

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
