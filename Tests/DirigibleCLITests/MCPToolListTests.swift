import Foundation
import Testing

/// The tool list of `dirigible mcp` (decision 0041).
struct MCPToolListTests {
    /// 75 tools in a fixed order, each with a description and a closed schema with `package`,
    /// except `devices` and `apps`, which take no argument.
    @Test func toolsListHasEachTool() async throws {
        let answers = try await mcp([modernRequest(1, "tools/list"), modernRequest(2, "tools/list")])
        let tools = result(answer(answers, id: 1))["tools"] as? [[String: Any]] ?? []
        #expect(
            tools.compactMap { $0["name"] as? String } == [
                "session_create", "session_info", "track_add", "track_add_call", "track_remove", "track_rename",
                "track_gain", "track_route", "track_layout", "track_mute", "track_solo", "track_role", "track_follow",
                "marker_set",
                "marker_remove", "episode_set", "episode_get",
                "capture_remove", "file_remove", "file_prune", "clip_place", "clip_clear", "clip_split",
                "clip_split_at", "clip_split_stereo", "clip_paste", "clip_paste_clips", "clip_replace", "clip_fill",
                "clip_nudge", "clip_remove",
                "clip_move",
                "clip_trim", "clip_gain", "clip_fade", "clip_denoise", "clip_repair", "clip_restore",
                "clip_crossfade", "clip_heal", "clip_close_gaps", "clip_roll", "clip_slip", "clip_envelope",
                "clip_gain_range", "clip_ripple_delete",
                "clip_ripple_insert", "clip_ripple_trim", "silence_edit",
                "transcript_import",
                "transcript_words", "transcript_cut", "transcribe", "transcript_export", "take_map", "backup_list",
                "backup_revert", "record", "transport_play", "transport_stop", "transport_locate", "loudness", "export",
                "render", "level", "duck", "import", "silences", "nearest_pause", "meter", "chapters_export",
                "chapters_import", "devices", "apps", "batch",
            ])
        for tool in tools {
            let name = tool["name"] as? String ?? ""
            let schema = tool["inputSchema"] as? [String: Any] ?? [:]
            #expect((tool["description"] as? String)?.isEmpty == false, "\(name)")
            #expect(schema["type"] as? String == "object" && schema["additionalProperties"] as? Bool == false)
            if ["devices", "apps"].contains(name) {
                // They read this Mac, not a package: no argument (W1).
                let properties = schema["properties"] as? [String: Any]
                #expect(properties?.isEmpty == true && schema["required"] == nil, "\(name): \(schema)")
                // The core rules ask for `package`, so the description says that these take none.
                #expect((tool["description"] as? String)?.hasSuffix(" It takes no argument.") == true, "\(name)")
            } else {
                #expect((schema["required"] as? [String])?.first == "package", "\(name)")
            }
        }
        #expect(NSArray(array: tools) == (result(answer(answers, id: 2))["tools"] as? NSArray), "two lists are equal")
        // The guide lists the tools by hand, so a new tool must also go there.
        let guide = try String(
            contentsOf: URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../docs/guide.md"),
            encoding: .utf8)
        #expect(guide.contains("The \(tools.count) tools"), "the guide gives another count of tools")
        for name in tools.compactMap({ $0["name"] as? String }) where !guide.contains("`\(name)`") {
            Issue.record("docs/guide.md does not name the tool \(name)")
        }
    }
}
