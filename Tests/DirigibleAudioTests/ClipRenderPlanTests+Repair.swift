import Foundation
import Testing

@testable import DirigibleAudio
@testable import DirigibleCore

/// The level rule of the repair kinds (decision 0064 D6): each requested kind goes to its stored
/// level, else joins the lowest level that holds a later kind, else one new level on top. An equal
/// request across two levels renders nothing.
extension ClipRenderPlanTests {
    func repair(_ effects: Effect...) -> ClipRenderRequest { ClipRenderRequest(Treatment(effects)!) }

    /// The 6 s mono noise file "f1" and the clip "c1" of 1 s at 2 s on "t1".
    func shortFixture() throws -> RenderFixture {
        let fixture = try RenderFixture()
        try fixture.add(
            "f1", [seededNoise(frames: 288_000, level: 0.01, seed: 25)], track: "t1", clips: [("c1", 96_000, 48_000)])
        return fixture
    }

    /// The treatments of each level of `plan`, bottom first, after a check that each entry is "c1".
    func treatments(_ plan: ClipRenderPlan) -> [[Treatment]] {
        #expect(plan.levels.allSatisfy { $0.allSatisfy { $0.clips == ["c1"] } }, "\(plan.levels)")
        return plan.levels.map { $0.map(\.request.treatment) }
    }

    /// The session of `fixture` after a render of each request in order on "c1".
    func stored(_ fixture: RenderFixture, _ requests: ClipRenderRequest...) throws -> Session {
        try requests.reduce(fixture.package.session) { try request(fixture, ["c1"], $1, of: $0).session }
    }

    /// C10: Repair Clipped Peaks on a clip with a noise level rebuilds that level as (declip,
    /// noise) from the root (fail: the 0057 rule, a new level on the noise output).
    @Test func declipJoinsTheNoiseLevel() throws {
        let fixture = try shortFixture()
        let session = try stored(fixture, twelve)

        let plan = try clipRenderPlan(["c1"], request: repair(.declip(.standard)), in: session)

        #expect(treatments(plan) == [[Treatment([.declip(.standard), .noise(.standard)])!]])
        #expect(plan.lowered.origins(of: "c1").isEmpty, "the level renders from the root")
    }

    /// C10: Soften "S" Sounds on a clip with a noise level is a new level on the noise output
    /// (fail: a join, which puts the de-ess before the noise reduction).
    @Test func deessGoesOnTop() throws {
        let fixture = try shortFixture()
        let session = try stored(fixture, twelve)

        let plan = try clipRenderPlan(["c1"], request: repair(.deess(.standard)), in: session)

        #expect(treatments(plan) == [[Treatment(.deess(.standard))]])
        #expect(plan.lowered.origins(of: "c1") == session.origins(of: "c1"), "the noise level stays")
    }

    /// C10: all three repairs on a clip with a noise level give (declip, rumble, noise) from the
    /// root and (deess) on its output, in one request (fail: one new level (declip, rumble, deess)
    /// on the noise output).
    @Test func allThreeOnANoiseClipSplitAroundTheNoiseLevel() throws {
        let fixture = try shortFixture()
        let session = try stored(fixture, twelve)
        let all = repair(.declip(.standard), .rumble(.standard), .deess(.standard))

        let outcome = try request(fixture, ["c1"], all, of: session)

        let origins = outcome.session.origins(of: "c1")
        let root = Treatment([.declip(.standard), .rumble(.standard), .noise(.standard)])!
        #expect(origins.map(\.treatment) == [Treatment(.deess(.standard)), root], "\(origins)")
        #expect(origins.last?.source == "f1" && outcome.made.count == 2, "\(origins)")
    }

    /// C10: rumble with a changed de-ess on the levels (noise) and (deess) joins the noise level,
    /// and the de-ess level takes the new value (fail: the 0057 "With one" branch, (rumble, deess)
    /// on the noise output).
    @Test func rumbleWithAChangedDeessJoinsTheNoiseLevel() throws {
        let fixture = try shortFixture()
        let session = try stored(fixture, twelve, repair(.deess(.standard)))
        let changed = DeEss(hertz: 5_000, decibels: 12)!

        let plan = try clipRenderPlan(["c1"], request: repair(.rumble(.standard), .deess(changed)), in: session)

        let noise = Treatment([.rumble(.standard), .noise(.standard)])!
        #expect(treatments(plan) == [[noise], [Treatment(.deess(changed))]])
        #expect(plan.lowered.origins(of: "c1").isEmpty, "both levels render from the root")
    }

    /// C10: a rumble request on a clip with a hum level joins the hum level.
    @Test func rumbleBeforeHumJoinsTheHumLevel() throws {
        let fixture = try shortFixture()
        let session = try stored(fixture, repair(.hum(.hz50)))

        let plan = try clipRenderPlan(["c1"], request: repair(.rumble(.standard)), in: session)

        #expect(treatments(plan) == [[Treatment([.rumble(.standard), .hum(.hz50)])!]])
        #expect(plan.lowered.origins(of: "c1").isEmpty)
    }

    /// C10, render-link C4 case "noise, then hum only": a hum request with no removal on a clip with
    /// a noise level gives one level (hum, noise) from the root (fail: two levels).
    @Test func humJoinsTheNoiseLevel() throws {
        let fixture = try shortFixture()
        let session = try stored(fixture, twelve)

        let plan = try clipRenderPlan(["c1"], request: repair(.hum(.hz50)), in: session)

        #expect(treatments(plan) == [[Treatment([.hum(.hz50), .noise(.standard)])!]])
        #expect(plan.lowered.origins(of: "c1").isEmpty)
    }

    /// C10: after a de-clip joins a hum level, Restore Original puts the clip back on the root at
    /// its frames and gain.
    @Test func restoreAfterAJoinGoesToTheRoot() throws {
        let fixture = try shortFixture()
        let original = try #require(fixture.package.session.clip("c1")?.clip)
        var session = try stored(fixture, repair(.hum(.hz50)), repair(.declip(.standard)))
        try #require(session.origins(of: "c1").map(\.treatment) == [Treatment([.declip(.standard), .hum(.hz50)])!])

        try session.restoreOriginals(["c1"])

        #expect(session.clip("c1")?.clip == original && session.origins(of: "c1").isEmpty)
    }

    /// C10: for random request sequences (a random set of kinds and values, random removals, or
    /// Restore Original), after each request the levels hold each kind once, bottom to top in
    /// chain order, with each requested value, no removed kind, and each other stored effect (fail:
    /// the 0057 "With one" branch, broken by noise, then deess, then rumble with a changed deess).
    @Test func levelOrderHoldsForEachRequestSequence() {
        var random = SeededGenerator(seed: 64)
        for sequence in 0..<300 {
            var chain: [Treatment] = []  // top first, as `Session.origins(of:)`
            for step in 0..<12 {
                guard Int.random(in: 0..<10, using: &random) > 0 else {
                    chain = []
                    continue
                }
                let request = randomRequest(&random)
                let before = Set(chain.flatMap(\.effects))

                if let rebuilt = levelRequests(request, on: chain) {
                    chain = rebuilt.requests.reversed().map(\.treatment) + chain[(rebuilt.lowest + 1)...]
                } else {
                    chain.insert(request.treatment, at: 0)
                }

                let context = "sequence \(sequence) step \(step): \(request) gives \(chain)"
                let bottomUp = chain.reversed().map { $0.effects.map(\.kind.rawValue) }
                let ordered = zip(bottomUp, bottomUp.dropFirst()).allSatisfy { $0.max()! < $1.min()! }
                let wanted = before.filter { !request.touched.contains($0.kind) }.union(request.treatment.effects)
                let kept = Set(chain.flatMap(\.effects)) == wanted
                #expect(ordered && kept, "ordered \(ordered), kept \(kept), \(context)")
                guard ordered && kept else { return }
            }
        }
    }

    /// A request of 1 to 5 kinds with random values, and each other kind removed at 1 in 4.
    func randomRequest(_ random: inout SeededGenerator) -> ClipRenderRequest {
        let kinds = Effect.Kind.allCases.filter { _ in Bool.random(using: &random) }
        let chosen = kinds.isEmpty ? [Effect.Kind.allCases.randomElement(using: &random)!] : kinds
        let effects: [Effect] = chosen.map { kind in
            switch kind {
            case .declip: .declip(Declip(percent: .random(in: Declip.range, using: &random))!)
            case .rumble: .rumble(Rumble(hertz: .random(in: Rumble.range, using: &random))!)
            case .hum: .hum(Hum.allCases.randomElement(using: &random)!)
            case .noise: .noise(NoiseReduction(decibels: .random(in: NoiseReduction.range, using: &random))!)
            case .deess:
                .deess(
                    DeEss(
                        hertz: .random(in: DeEss.hertzRange, using: &random),
                        decibels: .random(in: DeEss.decibelRange, using: &random))!)
            }
        }
        let removed = Effect.Kind.allCases.filter { !chosen.contains($0) && Int.random(in: 0..<4, using: &random) == 0 }
        return ClipRenderRequest(Treatment(effects)!, removing: Set(removed))
    }

    /// C11: an equal repair on the levels (declip, rumble, hum) and (deess), as Remove hum and then
    /// all three repairs make them, renders nothing: no file, the same session and bytes (fail: a
    /// compare with the lowest level only renders again). A changed de-ess renders both levels.
    @Test func equalRepairMakesNothing() throws {
        let fixture = try shortFixture()
        let root = repair(.declip(.standard), .rumble(.standard), .hum(.hz50))
        let plan = ClipRenderPlan(
            lowered: fixture.package.session, levels: [[(["c1"], root)], [(["c1"], repair(.deess(.standard)))]],
            unchanged: [])
        let session = try levels(fixture, plan).session
        let before = try fixture.hashes()
        let all = repair(.declip(.standard), .rumble(.standard), .deess(.standard))

        let again = try request(fixture, ["c1"], all, of: session)

        #expect(again.unchanged == ["c1"] && again.clips.isEmpty && again.made.isEmpty)
        let after = try fixture.hashes()
        #expect(again.session == session && after == before)
        let changed = repair(.declip(.standard), .rumble(.standard), .deess(DeEss(hertz: 6_000, decibels: 12)!))
        #expect(try request(fixture, ["c1"], changed, of: session).made.count == 2, "control")
    }

    /// C11: a repaired clip trimmed out to the edge of its rendered file renders again at the same
    /// values.
    @Test func widerRepairRendersAgain() throws {
        let fixture = try fixture()
        let both = repair(.declip(.standard), .rumble(.standard))
        var session = try request(fixture, ["c1"], both, of: fixture.package.session).session
        try session.trim("c1", to: 576_000..<1_104_000)

        let again = try request(fixture, ["c1"], both, of: session)

        #expect(again.unchanged.isEmpty && again.made.count == 1)
        let file = try #require(again.session.clip("c1")?.clip.file)
        #expect(again.session.files[file]?.origin?.offset == 96_000 && again.session.files[file]?.length == 1_152_000)
    }
}
