import Foundation
import Testing
import os

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

        /// Code gate 2 item 2: one `open` or `pread` of a model file can block with no end (a share
        /// that stops answering, a dataless iCloud file), and no stop reaches it. `settle()` ends
        /// the read and does not wait for it, so a close or a Quit does not hang. The late result
        /// is dropped: the call throws `.readClosed` and the session is as it was.
        @Test func aBlockedModelFileReadDoesNotDelaySettle() async throws {
            let fixture = try await ExportStudioFixture.make()
            let (studio, file) = try await Self.open(
                fixture.package, helper: fixture.package.folder.url.appending(path: "no-helper"),
                engine: Self.engine(ModelRecord()))
            let (entered, gate, settled) = (
                OSAllocatedUnfairLock(initialState: false), OSAllocatedUnfairLock(initialState: false),
                OSAllocatedUnfairLock(initialState: false)
            )
            studio.environment.hashModelFile = { _, _ throws(ModelFileCheckError) in
                entered.withLock { $0 = true }
                while !gate.withLock({ $0 }) { usleep(1_000) }
                return String(repeating: "0", count: 64)
            }
            let revision = studio.sessionRevision
            let hash = Task { () -> StudioError? in
                do throws(StudioError) {
                    _ = try await studio.hashModelFile(file)
                    return nil
                } catch {
                    return error
                }
            }
            await until(limit: .seconds(10), "the read blocks") { entered.withLock { $0 } }

            let settle = Task {
                await studio.settle()
                settled.withLock { $0 = true }
            }
            await until(limit: .seconds(5), "settle returns while the read blocks") { settled.withLock { $0 } }
            let returned = settled.withLock { $0 }
            gate.withLock { $0 = true }
            await settle.value

            #expect(returned, "settle waited for the blocked read")
            #expect(await hash.value == .readClosed)
            #expect(studio.readRuns.isEmpty && studio.sessionRevision == revision)
        }
    }
#endif
