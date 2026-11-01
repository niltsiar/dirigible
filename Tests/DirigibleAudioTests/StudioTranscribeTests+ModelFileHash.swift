import Foundation
import Testing

@testable import DirigibleAudio

#if DEBUG
    /// The hash of a kept model file for the Transcribe sheet (decision 0065, D8, C24).
    extension StudioTranscribeModelFileTests {
        /// C24: the sheet hash of a kept file is a read run, so `endReads(.take)`, as each take start
        /// calls it, ends it with `.readYielded` at the next chunk of a 16 GiB file.
        @Test func aTakeStartEndsTheSheetHash() async throws {
            let fixture = try await ExportStudioFixture.make()
            let (studio, _) = try await Self.open(
                fixture.package, helper: fixture.package.folder.url.appending(path: "no-helper"),
                engine: Self.engine(ModelRecord()))
            let big = fixture.package.folder.url.appending(path: "big.bin")
            FileManager.default.createFile(atPath: big.path, contents: nil)
            #expect(truncate(big.path, 16 << 30) == 0)
            let hash = Task { () -> StudioError? in
                do throws(StudioError) {
                    _ = try await studio.hashModelFile(big)
                    return nil
                } catch {
                    return error
                }
            }

            await until(limit: .seconds(10), "the hash joins the read runs") { !studio.readRuns.isEmpty }
            studio.endReads(.take)

            #expect(await hash.value == .readYielded)
            await studio.settle()
        }
    }
#endif
