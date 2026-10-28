import Foundation
import Testing

@testable import DirigibleAudio
@testable import DirigibleCore

/// The render plan of a request (decision 0057): a change renders from the source of its level,
/// an equal request renders nothing, and the levels share one space check, one progress, and one
/// cleanup. Each render runs AUSoundIsolation.
struct ClipRenderPlanTests {
    let twelve = ClipRenderRequest(Treatment(.noise(.standard)))

    func amount(_ decibels: Int) -> ClipRenderRequest {
        ClipRenderRequest(Treatment(.noise(NoiseReduction(decibels: decibels)!)))
    }

    /// The 26 s mono noise file "f1" and the clip "c1" of 1 s at 12 s on "t1". Its run is 2 s to
    /// 23 s, so the file has 3 s past the rendered file on the right.
    func fixture() throws -> RenderFixture {
        let fixture = try RenderFixture()
        try fixture.add(
            "f1", [seededNoise(frames: 1_248_000, level: 0.01, seed: 21)], track: "t1",
            clips: [("c1", 576_000, 48_000)])
        return fixture
    }

    func request(
        _ fixture: RenderFixture, _ clips: [ClipID], _ request: ClipRenderRequest, of session: Session
    ) throws(ClipRenderError) -> ClipRenderOutcome {
        try renderRequest(
            clips, request: request, of: session, in: fixture.package.url, freeBytes: { .max },
            isDownloaded: { _ in true })
    }

    /// Two levels of c1 by hand: 12 dB, then 6 dB on the file of the first level.
    func twoLevels(_ fixture: RenderFixture) -> ClipRenderPlan {
        ClipRenderPlan(
            lowered: fixture.package.session, levels: [[(["c1"], twelve)], [(["c1"], amount(6))]], unchanged: [])
    }

    func levels(
        _ fixture: RenderFixture, _ plan: ClipRenderPlan, freeBytes: Int64 = .max, readFault: ReadFault? = nil,
        progress: @escaping (Double) -> Void = { _ in }, isCancelled: @escaping () -> Bool = { false }
    ) throws(ClipRenderError) -> ClipRenderOutcome {
        try renderLevels(
            plan, in: fixture.package.url, freeBytes: { freeBytes }, readFault: readFault,
            isDownloaded: { _ in true }, progress: progress, isCancelled: isCancelled)
    }

    /// C3: a new amount on a rendered clip gives the samples and the clip of Restore Original and
    /// then a render at that amount, and the new file names the root.
    @Test func changeEqualsRestoreAndRender() throws {
        let fixture = try fixture()
        let first = try request(fixture, ["c1"], twelve, of: fixture.package.session)

        let changed = try request(fixture, ["c1"], amount(20), of: first.session)

        var restored = first.session
        try restored.restoreOriginals(["c1"])
        let fresh = try request(fixture, ["c1"], amount(20), of: restored)
        let (a, b) = (try #require(changed.session.clip("c1")?.clip), try #require(fresh.session.clip("c1")?.clip))
        #expect(a.offset == b.offset && a.length == b.length && a.gain == b.gain && a.envelope == b.envelope)
        let (x, y) = (try fixture.samples(a.file, in: changed.session), try fixture.samples(b.file, in: fresh.session))
        #expect(x.count == y.count && maxError(x, y) <= 1e-6, "the change stacks on the rendered file")
        let origins = changed.session.origins(of: "c1")
        #expect(origins.map(\.source) == ["f1"] && origins.first?.treatment == amount(20).treatment, "\(origins)")
    }

    /// C4: two noise levels give one: the request rebuilds the lowest noise level, and the noise
    /// level above it goes.
    @Test func oneKindKeepsOneLevel() throws {
        let fixture = try fixture()
        let stacked = try levels(fixture, twoLevels(fixture)).session
        try #require(stacked.origins(of: "c1").count == 2)

        let changed = try request(fixture, ["c1"], amount(20), of: stacked)

        let origins = changed.session.origins(of: "c1")
        #expect(origins.map(\.source) == ["f1"] && origins.first?.treatment == amount(20).treatment, "\(origins)")
    }

    /// C4: one level with two requests for two adjacent clips of one file renders two files and
    /// no `.mixedTreatments`.
    @Test func adjacentClipsWithTwoRequestsRenderApart() throws {
        let fixture = try RenderFixture()
        try fixture.add(
            "f1", [seededNoise(frames: 1_248_000, level: 0.01, seed: 22)], track: "t1",
            clips: [("a", 576_000, 48_000), ("b", 624_000, 48_000)])
        let plan = ClipRenderPlan(
            lowered: fixture.package.session, levels: [[(["a"], twelve), (["b"], amount(20))]], unchanged: [])

        let outcome = try levels(fixture, plan)

        #expect(outcome.made.count == 2)
        #expect(outcome.session.origins(of: "a").map(\.treatment) == [twelve.treatment])
        #expect(outcome.session.origins(of: "b").map(\.treatment) == [amount(20).treatment])
    }

    /// C5: the amount of the level again renders nothing: no file, the same session, and the clip
    /// in `unchanged`. Another amount renders.
    @Test func equalSettingMakesNothing() throws {
        let fixture = try fixture()
        let first = try request(fixture, ["c1"], twelve, of: fixture.package.session)
        let before = try fixture.hashes()

        let again = try request(fixture, ["c1"], twelve, of: first.session)

        #expect(again.unchanged == ["c1"] && again.clips.isEmpty && again.made.isEmpty)
        let after = try fixture.hashes()
        #expect(again.session == first.session && after == before)
        #expect(try request(fixture, ["c1"], amount(20), of: first.session).made.count == 1, "control")
    }

    /// C5: the left half of a rendered clip, with the right half deleted, renders nothing at the
    /// same amount: its file covers its new span.
    @Test func narrowerSpanMakesNothing() throws {
        let fixture = try fixture()
        var session = try request(fixture, ["c1"], twelve, of: fixture.package.session).session
        let right = try session.split("c1", at: 600_000)
        try session.removeClips([right])

        let again = try request(fixture, ["c1"], twelve, of: session)

        #expect(again.unchanged == ["c1"] && again.made.isEmpty && again.session == session)
    }

    /// C5: a clip trimmed out to the edge of its rendered file needs frames past that file, so the
    /// same amount renders again.
    @Test func trimWiderRendersAgain() throws {
        let fixture = try fixture()
        var session = try request(fixture, ["c1"], twelve, of: fixture.package.session).session
        try session.trim("c1", to: 576_000..<1_104_000)

        let again = try request(fixture, ["c1"], twelve, of: session)

        #expect(again.unchanged.isEmpty && again.made.count == 1)
        let file = try #require(again.session.clip("c1")?.clip.file)
        #expect(again.session.files[file]?.origin?.offset == 96_000 && again.session.files[file]?.length == 1_152_000)
    }

    /// C5: in a request where one clip changes, the unchanged clip keeps its file, offset, gain,
    /// and envelope.
    @Test func unchangedClipKeepsItsFileInAMixedRequest() throws {
        let fixture = try fixture()
        try fixture.add(
            "f2", [seededNoise(frames: 240_000, level: 0.01, seed: 23)], track: "t2", clips: [("c2", 48_000, 48_000)])
        let first = try request(fixture, ["c1"], twelve, of: fixture.package.session)
        let kept = try #require(first.session.clip("c1")?.clip)

        let outcome = try request(fixture, ["c1", "c2"], twelve, of: first.session)

        #expect(outcome.session.clip("c1")?.clip == kept && outcome.unchanged == ["c1"])
        #expect(outcome.clips.map(\.clip) == ["c2"] && outcome.session.origins(of: "c2").map(\.source) == ["f2"])
    }

    /// C15: one space check for the first level times the number of levels: free bytes equal to
    /// the bound and the margin render both levels; one byte less writes nothing.
    @Test func spaceFailsBeforeTheFirstLevel() throws {
        let fixture = try fixture()
        let needed = 2 * 1_008_000 * 3 + diskMargin
        let before = try fixture.hashes()

        #expect(throws: ClipRenderError.space(needed: needed, free: needed - 1)) {
            try levels(fixture, twoLevels(fixture), freeBytes: needed - 1)
        }
        #expect(try fixture.hashes() == before)
        #expect(try levels(fixture, twoLevels(fixture), freeBytes: needed).made.count == 2)
    }

    /// C17: over two levels the progress only rises, and 1 comes once, last.
    @Test func progressRisesOnceToOne() throws {
        let fixture = try fixture()
        var fractions: [Double] = []

        _ = try levels(fixture, twoLevels(fixture), progress: { fractions.append($0) })

        #expect(fractions.count > 8 && zip(fractions.dropFirst(), fractions).allSatisfy { $0 > $1 }, "\(fractions)")
        #expect(fractions.last == 1 && fractions.filter { $0 == 1 }.count == 1, "\(fractions)")
    }

    /// A cancel in the second level removes the file of the first level too. The second level
    /// renders "f1 NR NR" from "f1 NR".
    @Test func cancelRemovesEachLevel() throws {
        let fixture = try fixture()
        let before = try fixture.listing()
        let late = LockedBox<Bool>()
        let fault = ReadFault(stem: "f1 NR NR", block: 1) { late.value = true }

        #expect(throws: ClipRenderError.cancelled) {
            try levels(fixture, twoLevels(fixture), readFault: fault, isCancelled: { late.value == true })
        }
        #expect(late.value == true, "the cancel came in the second level")
        #expect(try fixture.listing() == before)
    }
}
