import DirigibleCore

extension Studio {
    /// The listened tracks whose device plays no monitor sound (decision 0044): the device is
    /// absent, the output failed, or the Listener stopped retrying. Computed from the request, so
    /// a track that leaves the request is never quiet.
    public var quietListens: Set<TrackID> {
        Set(
            listenRequest.filter { id in
                guard case .device(let uid, _) = session.track(id)?.route else { return false }
                return quietDevices.contains(uid)
            })
    }

    /// Plays the input of each device track of `tracks` in the default output (decision 0044),
    /// before, during, and after a take. An app route has no listen. No take step and no
    /// finalize changes it, and it runs in the listen order, so it never waits for them. The last
    /// call wins. A device that leaves the request plays zeros before the first await and is
    /// released before the return. Throws `.microphoneAccess` when the access is not granted;
    /// then it holds no device. During a settle it does nothing.
    public func listen(to tracks: [TrackID]) async throws(StudioError) {
        guard !settling else { return }
        listenRequest = tracks
        var released = releaseListeners()
        if !listenPlan().isEmpty, let access = await microphoneAccess(of: environment), listenRequest == tracks {
            listenRequest = []
            released += releaseListeners()
            await listenTurns.run { await applyListen(releasing: released) }
            throw .microphoneAccess(access)
        }
        await listenTurns.run { await applyListen(releasing: released) }
    }

    /// Settle: no Listener after the return.
    func endListen() async {
        listenRequest = []
        let released = releaseListeners()
        await listenTurns.run { await applyListen(releasing: released) }
    }

    /// The channels of the device tracks of the request, by device UID.
    private func listenPlan() -> [String: [Route.Channels]] {
        var plan: [String: [Route.Channels]] = [:]
        for id in listenRequest {
            guard case .device(let uid, let channels) = session.track(id)?.route else { continue }
            plan[uid, default: []].append(channels)
        }
        return plan
    }

    /// A8: mutes and removes the Listener of each device that the request no longer has, with no
    /// await. The caller turns them off in a listen turn.
    private func releaseListeners() -> [Listener] {
        let plan = listenPlan()
        var released: [Listener] = []
        for (uid, entry) in listeners where plan[uid] == nil {
            entry.listener.mute()
            listeners[uid] = nil
            quietDevices.remove(uid)
            released.append(entry.listener)
        }
        return released
    }

    /// Gives each listened device its map, or a new Listener, then turns `released` off.
    private func applyListen(releasing released: [Listener]) async {
        for (uid, routes) in listenPlan() {
            let map = ChannelMap(routes: routes)
            if let entry = listeners[uid] {
                entry.listener.setMap(map)
                continue
            }
            listenNumber += 1
            let listener = Listener(
                uid: uid, map: map, hal: environment.hal, output: environment.listenOutput,
                report: Self.listenReporter(to: self, number: listenNumber, uid: uid))
            listeners[uid] = (listener, listenNumber)
            listener.start()
        }
        for listener in released { await listener.off() }
    }

    nonisolated static func listenReporter(to studio: Studio, number: Int, uid: String)
        -> @Sendable (ListenReport) -> Void
    {
        { [weak studio] report in Task { @MainActor in studio?.applyListen(report, number: number, uid: uid) } }
    }

    /// A report of a Listener that is not the current one of `uid` changes nothing.
    func applyListen(_ report: ListenReport, number: Int, uid: String) {
        guard listeners[uid]?.number == number else { return }
        if report == .quiet { quietDevices.insert(uid) } else { quietDevices.remove(uid) }
    }
}
