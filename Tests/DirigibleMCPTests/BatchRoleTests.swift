import Testing

@testable import DirigibleMCP

/// Each tool of `Tool.all` names its batch role (decision 0063). A new tool must join one of the
/// two lists below, and this test fails until it does.
struct BatchRoleTests {
    /// The 34 tools whose call can be a step: 30 always, and 4 when the call copies no file.
    static let steps: Set<String> = [
        "track_add", "track_add_call", "track_remove", "track_rename", "track_gain", "track_route", "track_layout",
        "track_mute", "track_solo", "track_role", "marker_set", "marker_remove", "episode_set", "capture_remove",
        "file_remove", "clip_place", "clip_clear", "clip_split", "clip_split_at", "clip_paste", "clip_paste_clips",
        "clip_nudge", "clip_remove", "clip_move", "clip_trim", "clip_gain", "clip_fade", "clip_crossfade",
        "clip_heal", "clip_envelope", "clip_gain_range", "clip_ripple_delete", "clip_ripple_insert",
        "clip_ripple_trim",
    ]

    /// The 30 tools that are never a step.
    static let alone: Set<String> = [
        "session_create", "session_info", "episode_get", "file_prune", "backup_list", "backup_revert",
        "clip_split_stereo", "transcript_import", "transcript_words", "transcript_cut", "transcript_export",
        "take_map", "record", "transport_play", "transport_stop", "transport_locate", "loudness", "export", "render",
        "level", "duck", "import", "silences", "nearest_pause", "meter", "chapters_export", "chapters_import",
        "devices", "apps", "batch",
    ]

    /// The `batch` description names its steps by tool family. Each tool of a named family is a
    /// step, or the description names it as an exception.
    @Test func theBatchDescriptionMatchesTheRoles() throws {
        let description = try #require(Tool.all.first { $0.name == "batch" }).description
        for family in ["track", "marker", "episode", "clip", "ripple"] {
            #expect(description.contains(family), "the description does not name the \(family) tools")
            let alone = Tool.all.filter {
                $0.name.split(separator: "_").contains(Substring(family)) && $0.batch == .alone
            }
            let unnamed = alone.map(\.name).filter { !description.contains($0) }
            #expect(
                unnamed.isEmpty,
                "BATCH-A6 \(family) tools that are not steps and that the text does not name: \(unnamed)")
        }
    }

    /// An agent reads each tool name after "except" in the `batch` description as refused, and each
    /// other tool name as a step. The word "batch" in the text is the tool itself, not a step.
    @Test func aToolAfterExceptIsRefusedAndEachOtherNamedToolIsAStep() throws {
        let description = try #require(Tool.all.first { $0.name == "batch" }).description
        let names = Self.steps.union(Self.alone).subtracting(["batch"])
        let tokens = description.matches(of: /\w+|[^\w\s]/).map { String($0.output) }
        var excepted: Set<String> = []
        var named: Set<String> = []
        var index = 0
        while index < tokens.count {
            guard tokens[index] == "except" else {
                if names.contains(tokens[index]) { named.insert(tokens[index]) }
                index += 1
                continue
            }
            index += 1
            while index < tokens.count, names.contains(tokens[index]) {
                excepted.insert(tokens[index])
                index += 1
                while index < tokens.count, [",", "and"].contains(tokens[index]) { index += 1 }
            }
        }
        #expect(!excepted.isEmpty && !named.isEmpty, "the scan found no tool names")
        let steps = excepted.subtracting(Self.alone)
        #expect(steps.isEmpty, "BATCH-A6 steps that the text names after except: \(steps.sorted())")
        let refused = named.subtracting(Self.steps)
        #expect(refused.isEmpty, "BATCH-A6 refused tools that the text names as steps: \(refused.sorted())")
    }

    @Test func eachToolHasItsBatchRole() {
        #expect(Self.steps.count == 34 && Self.alone.count == 30 && Self.steps.isDisjoint(with: Self.alone))
        let names = Tool.all.map(\.name)
        let unlisted = Set(names).subtracting(Self.steps).subtracting(Self.alone)
        #expect(unlisted.isEmpty, "BATCH-S2-6 tools in neither list: \(unlisted.sorted())")
        let gone = Self.steps.union(Self.alone).subtracting(names)
        #expect(gone.isEmpty, "names that are not tools: \(gone.sorted())")
        for tool in Tool.all {
            let expected: Tool.BatchRole = Self.steps.contains(tool.name) ? .step : .alone
            #expect(tool.batch == expected, "\(tool.name) has the role \(tool.batch), the list says \(expected)")
        }
    }
}
