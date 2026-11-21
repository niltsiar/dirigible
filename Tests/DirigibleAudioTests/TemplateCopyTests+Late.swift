import DirigibleCore
import Foundation
import Testing

@testable import DirigibleAudio

/// A copy that ends after its last file (code gate 1, items 6 and 7).
extension TemplateCopyTests {
    /// A cancel after the last file, before `session.xml`, makes nothing and does not write the session.
    @Test func aCancelAfterTheLastFileMakesNothing() throws {
        let fixture = try TemplateFixture()
        let flushes = Flushes()
        var cancelled = false
        // The flush of the staging folder is the last step before `session.xml`.
        flushes.action = { path in if path.hasSuffix(".template") { cancelled = true } }
        var seams = seams(flushes)
        var wrote = false
        seams.writeSession = { session, folder throws(SessionFileError) in
            wrote = true
            try session.write(to: folder)
        }

        #expect(throws: TemplateError.cancelled) { try fixture.copy(seams: seams, isCancelled: { cancelled }) }
        #expect(flushes.paths.contains { $0.hasSuffix(".template") }, "the cancel came after the last flush")
        #expect(!wrote && madeNothing(fixture))
    }

    /// A cancel while `session.xml` is written makes nothing: the publish does not run.
    @Test func aCancelDuringTheSessionWriteMakesNothing() throws {
        let fixture = try TemplateFixture()
        var cancelled = false
        var seams = TemplateCopySeams()
        seams.writeSession = { session, folder throws(SessionFileError) in
            try session.write(to: folder)
            cancelled = true
        }

        #expect(throws: TemplateError.cancelled) { try fixture.copy(seams: seams, isCancelled: { cancelled }) }
        #expect(madeNothing(fixture), "no package, staging folder, or lock file")
    }

    /// A fault of the write of `session.xml` is not a read failure of the template: the CLI text of `.read` names
    /// the template.
    @Test func aSessionWriteFaultIsNotAReadFailure() throws {
        let fixture = try TemplateFixture()
        var seams = TemplateCopySeams()
        seams.writeSession = { _, _ throws(SessionFileError) in throw .wouldNotReadBack(nil) }

        #expect(throws: TemplateError.publish(.wouldNotReadBack(nil))) { try fixture.copy(seams: seams) }
        #expect(madeNothing(fixture))
    }

    /// A write that fails with an errno names `session.xml` and the errno.
    @Test func aSessionWriteErrnoIsAWriteFailure() throws {
        let fixture = try TemplateFixture()
        var seams = TemplateCopySeams()
        seams.writeSession = { _, _ throws(SessionFileError) in throw .writeFailed(step: "rename", errno: ENOSPC) }

        #expect(throws: TemplateError.write(file: "session.xml", errno: ENOSPC)) { try fixture.copy(seams: seams) }
        #expect(madeNothing(fixture))
    }
}
