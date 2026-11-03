import DirigibleCore

/// The pre-roll take of decision 0070: the take play of the Player between the checks and the
/// save of a take start, and its end.
extension Studio {
    /// The session that the Player plays: during a pre-roll take, the take mix of the session, so
    /// an edit in the take keeps the armed tracks silent from T (**One Player session**).
    var playerSession: Session {
        guard case .recording = transport, let recording = session.recording, recording.isPreRoll else {
            return session
        }
        return takeMix(session, armed: recording.armedTracks, from: recording.playheadFrame)
    }

    /// The step of a pre-roll take start after its checks and before its save (**Start order**):
    /// the take mix, the take play from S = `seconds` (0 to 10) before `playhead`, then H_T. With no
    /// output term, it stops the Player, keeps the playhead at T, and throws `.outputTermUnavailable`.
    func startPreRoll(at playhead: Frames, seconds: Int, armed: [TrackID]) async throws(StudioError) -> UInt64 {
        let rate = session.sampleRate
        let start = preRollStart(playhead: playhead, seconds: min(max(seconds, 0), 10), rate: rate)
        let player = play.player ?? makePlayer()
        play.player = player
        // Awaited with a new revision, so no late plain session replaces the take mix.
        play.revision += 1
        await player.update(takeMix(session, armed: armed, from: playhead), revision: play.revision)
        play.feed += 1
        let take = Player.TakeStart(floor: environment.hostNanos() + Player.startMargin, span: playhead - start)
        let span = environment.log.begin(.take, "pre-roll-begin", ["from": .number(Int64(start.count))])
        let shuttle = Shuttle(direction: .forward, rate: .one)
        await player.apply(.play(from: start, shuttle: shuttle, take: take), number: play.feed)
        let reading = await player.reading()
        guard reading.termFault == nil, let realStart = reading.realStart else {
            environment.log.note(.take, "pre-roll-fault", level: .error, fields: reading.termFault?.journalFields ?? [])
            await endPreRoll(at: playhead)
            throw .outputTermUnavailable
        }
        let anchor = takeStartHostNanos(realStart: realStart, term: reading.term, from: start, to: playhead, rate: rate)
        let lead = anchor - min(anchor, environment.hostNanos())
        span.end(
            "pre-roll", fields: preRollFields(lead: lead, realStart: realStart, term: reading.term, takeStart: anchor))
        return anchor
    }

    /// The anchor step of `prepareTake` for a pre-roll take: `startPreRoll`.
    func preRollStep(seconds: Int, at playhead: Frames, armed: [TrackID]) -> TakeAnchorStep {
        {
            do throws(StudioError) {
                return .success(try await self.startPreRoll(at: playhead, seconds: seconds, armed: armed))
            } catch {
                return .failure(error)
            }
        }
    }

    /// After a refused pre-roll take start: a save fault after the pre-roll step stops its take play.
    func endFaultedPreRoll(at playhead: Frames) async {
        guard await play.player?.reading().realStart != nil else { return }
        await endPreRoll(at: playhead)
    }

    /// Stops the take play of a pre-roll take and puts the playhead at T (**Stop**).
    func endPreRoll(at playhead: Frames) async {
        _ = await endFeed(stop: true)
        play.playhead = playhead
    }
}

/// The fields of the journal line of a pre-roll take start (decision 0070, P24): the lead from
/// the return of the play command, the real start host time, the output term in its parts, and
/// H_T. The parts of a device term are in device frames, with the device rate and UID.
func preRollFields(lead: UInt64, realStart: UInt64, term: OutputTerm, takeStart: UInt64)
    -> [(key: String, value: DiagnosticValue)]
{
    let parts: [(key: String, value: DiagnosticValue)] =
        switch term {
        case .device(let device):
            [
                ("latency", .number(Int64(device.latency))), ("stream", .number(Int64(device.streamLatency))),
                ("safety", .number(Int64(device.safetyOffset))), ("buffer", .number(Int64(device.bufferFrames))),
                ("rate", .number(Int64(device.rate.rounded()))), ("output", .uid(device.uid)),
            ]
        case .manual(let frames): [("frames", .number(Int64(frames)))]
        }
    return [("lead", .milliseconds(Double(lead) / 1e6)), ("start", .number(Int64(realStart)))] + parts
        + [("ht", .number(Int64(takeStart)))]
}

extension StartedTake {
    /// The late start limit of the writers (decision 0070, **Late start**): H_T of a pre-roll take;
    /// nil for a Command-R take, which never checks it.
    var lateStartLimit: UInt64? {
        session.recording.flatMap { $0.isPreRoll ? $0.takeStartHostTimeNanos : nil }
    }
}
