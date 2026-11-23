import DirigibleAudio
import DirigibleCore
import Foundation
import Observation

/// The Favorites store of the app (F23, decision 0081): the store as last read, and the one writer
/// of the store in this process. Each session window reads it. With no store (an app in a test),
/// the list is empty, Add to Favorites is off, and the model reads and writes nothing.
@Observable @MainActor final class FavoritesModel {
    /// The store as last read: its session, or the fault of its read.
    enum State: Equatable {
        case loaded(Session)
        /// The store does not read; the Favorites section shows the text of the fault and no alert.
        case fault(StudioError)
    }

    /// Nil with no store.
    @ObservationIgnored let writer: FavoritesWriter?
    private(set) var state: State = .loaded(Session(sampleRate: Favorites.sampleRate))
    /// The identity of the store package at the last read: the origin of a paste of a favorite
    /// (decision 0042). Nil for a store with no `.lock` file.
    @ObservationIgnored private(set) var identity: PackageID?
    /// The number of the last reload, so the result of an older read does not replace a newer one.
    @ObservationIgnored private var reloads = 0
    /// The number of the reload whose read the state holds.
    @ObservationIgnored private var landed = 0
    /// The reloads that wait for a newer read to land.
    @ObservationIgnored private(set) var waiting: [CheckedContinuation<Void, Never>] = []
    /// Runs before each store read, off the main actor. A test holds a read here.
    @ObservationIgnored var readStep: @Sendable () async -> Void = {}

    init(store: URL?) { writer = store.map(FavoritesWriter.init(store:)) }

    var canAdd: Bool { writer != nil }

    /// The favorite groups, in user order; none while the store has a fault.
    var bins: [Bin] {
        if case .loaded(let session) = state { session.bins } else { [] }
    }

    /// Reads the store `session.xml` again, with no lock, off the main actor. A store folder or a
    /// `session.xml` that does not exist reads as an empty store; each other read error is a fault.
    /// It returns when the state holds the read of the newest reload, so a caller sees its own read
    /// or a newer one.
    func reload() async {
        guard let store = writer?.store else { return }
        reloads += 1
        let reload = reloads
        await readStep()
        let read = await Self.read(store)
        if reload == reloads {
            (state, identity) = read
            landed = reload
            for waiter in waiting { waiter.resume() }
            waiting = []
        } else if landed < reloads {
            await withCheckedContinuation { waiting.append($0) }
        }
    }

    /// Runs `body` on the store through the one writer, after each earlier store write of the app,
    /// then reads the store again, also after a fault. Nil with no store.
    func edit<Value: Sendable>(_ body: @escaping @Sendable (inout Session) throws(SessionError) -> Value)
        async throws(StudioError) -> Value?
    {
        guard let writer else { return nil }
        let result = await writer.edit(log: .disabled, body)
        await reload()
        return try result.get()
    }

    @concurrent nonisolated private static func read(_ store: URL) async -> (State, PackageID?) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let state: State
                do throws(SessionFileError) {
                    state = .loaded(try Session(contentsOf: store))
                } catch .readFailed(errno: ENOENT) {
                    state = .loaded(Session(sampleRate: Favorites.sampleRate))
                } catch {
                    state = .fault(StudioError(favoritesFile: error))
                }
                continuation.resume(returning: (state, PackageID(lockFileOf: store)))
            }
        }
    }
}
