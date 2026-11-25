import DirigibleCore
import Foundation

/// What the effect preview of a studio does (decision 0054). `updating`: a window renders, and
/// the old loop, if any, plays on.
public enum EffectPreviewState: Hashable, Sendable { case stopped, updating, playing }

/// The effect preview of a studio: the engine, made at the first preview, the number of the last
/// call, and the state.
struct EffectPreviewSlot {
    var engine: EffectPreview?
    var number = 0
    var state = EffectPreviewState.stopped
}

extension Studio {
    public var effectPreviewState: EffectPreviewState { effectPreview.state }

    /// Loops a 10 s window of `clip` rendered with `request`, as `listen` (decision 0054): from the
    /// playhead when it is inside the clip, else from the clip start. `clips` are the clips that
    /// the request renders, `clip` among them, so a de-clip measures the run of the render. A play
    /// stops first. A newer call wins: an older render ends and changes nothing, and the old loop
    /// plays until the new window is ready. Play, a take start, a blocking run, `settle()`, and a configuration change
    /// of the preview output stop it. It throws `.busy` when the studio is not idle, and a render
    /// fault stops the preview and throws it.
    public func startEffectPreview(_ request: ClipRenderRequest, of clip: ClipID, among clips: [ClipID], listen: Listen)
        async throws(StudioError)
    {
        try checkNotBusy()
        try checkReadable()
        let session = session
        let window: PreviewWindow
        do throws(SessionError) {
            window = try previewWindow(
                of: clip, among: clips, request: request, playhead: play.playhead, in: session)
        } catch {
            throw .clipRender(.session(error))
        }
        effectPreview.number += 1
        let number = effectPreview.number
        let engine = effectPreviewEngine()
        engine.supersede(number)
        effectPreview.state = .updating
        await stopPlay()
        do throws(StudioError) {
            guard try await engine.play(window, of: session, listen: listen, number: number) else { return }
        } catch {
            if effectPreview.number == number { effectPreview.state = .stopped }
            throw error
        }
        if effectPreview.number == number { effectPreview.state = .playing }
    }

    /// Stops the effect preview with no wait.
    public func stopEffectPreview() {
        guard effectPreview.state != .stopped, let engine = effectPreview.engine else { return }
        let number = takeEffectPreviewStop()
        Task { @concurrent in await engine.stop(number) }
    }

    /// Stops the effect preview and waits for the engine. `settle()` calls it.
    func endEffectPreview() async {
        guard let engine = effectPreview.engine else { return }
        await engine.stop(takeEffectPreviewStop())
    }

    /// A new call number for a stop, which ends each older call, and `.stopped`.
    private func takeEffectPreviewStop() -> Int {
        effectPreview.number += 1
        effectPreview.engine?.supersede(effectPreview.number)
        effectPreview.state = .stopped
        return effectPreview.number
    }

    /// The engine of the preview. Its output is the output of the Player.
    private func effectPreviewEngine() -> EffectPreview {
        if let engine = effectPreview.engine { return engine }
        let engine = EffectPreview(
            package: { [lock] () throws(SessionFileError) in try lock.package() },
            output: environment.playerOutput, rate: session.sampleRate, start: environment.startEngine,
            readFault: environment.clipRenderRead,
            ended: { [weak self] number in
                guard let self else { return }
                Task { @MainActor in self.effectPreviewEnded(number) }
            })
        effectPreview.engine = engine
        return engine
    }

    /// A configuration change of the preview output stopped the loop of the call `number`. It
    /// takes the stop number as each other stop does, so a window render in flight starts no loop.
    private func effectPreviewEnded(_ number: Int) {
        guard effectPreview.number == number else { return }
        _ = takeEffectPreviewStop()
    }
}
