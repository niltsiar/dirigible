import DirigibleCore
import Foundation
import Testing

/// The tool `clip_restore` on a closed package (decision 0057, run render-link C6), with the
/// fixture of `ClipRestoreCommandTests`.
struct MCPRestoreTests {
    let package: TemporaryPackage

    init() throws { package = try TemporaryPackage(try ClipRestoreCommandTests.rendered()) }

    func restore(_ clips: [String]) async throws -> (text: String, isError: Bool) {
        let answers = try await mcp([toolCall(1, "clip_restore", ["package": package.path, "clips": clips])])
        return toolResult(answer(answers, id: 1))
    }

    /// C6. The tool gives the ID of each restored clip and saves, as `clip restore` does. A second
    /// call has no rendered clip left.
    @Test func restoreGivesTheRestoredClips() async throws {
        let result = try await restore(["A", "P"])
        let again = try await restore(["A"])

        #expect(result == ("A", false), "\(result)")
        #expect(try package.read().clip("A")?.clip.file == "f")
        #expect(again == ("No rendered clip.", false), "\(again)")
    }

    /// C6. A clip given twice and an unknown clip are refused, and the file does not change.
    @Test func refusalsChangeNothing() async throws {
        let before = try package.xml()

        let twice = try await restore(["A", "A"])
        let unknown = try await restore(["X"])

        #expect(twice == ("Clip \"A\" is given twice.", true), "\(twice)")
        #expect(unknown.isError && unknown.text.contains("no clip \"X\""), "\(unknown)")
        #expect(try package.xml() == before)
    }
}
