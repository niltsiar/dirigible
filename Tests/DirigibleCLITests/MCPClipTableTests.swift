/// The C6 and C7 rows of the clip tools, on the fixture of `MCPEditTableTests`.
extension MCPEditTableTests {
    static var clipRows: [EditRow] {
        [
            EditRow(
                tool: "clip_place",
                arguments: ["track": "e", "file": "f", "start": 0, "length": 1000, "offset": 10, "db": -2, "id": "P"],
                command: [
                    "clip", "place", "PKG", "--track", "e", "--file", "f", "--start", "0", "--length", "1000",
                    "--offset",
                    "10", "--db", "-2", "--id", "P",
                ]),
            EditRow(
                tool: "clip_place", arguments: ["track": "e", "file": "f", "start": 0, "length": 1000],
                command: ["clip", "place", "PKG", "--track", "e", "--file", "f", "--start", "0", "--length", "1000"],
                generated: true),
            EditRow(
                tool: "clip_clear", arguments: ["track": ["a", "b"], "from": 10_000, "to": 100_000],
                command: ["clip", "clear", "PKG", "--track", "a", "--track", "b", "--from", "10000", "--to", "100000"]),
            EditRow(
                tool: "clip_split", arguments: ["clip": "A", "at": 24_000, "right_id": "R"],
                command: ["clip", "split", "PKG", "A", "--at", "24000", "--right-id", "R"]),
            EditRow(
                tool: "clip_split", arguments: ["clip": "A", "at": 24_000],
                command: ["clip", "split", "PKG", "A", "--at", "24000"]),
            EditRow(
                tool: "clip_split_at", arguments: ["track": ["a", "b"], "at": [24_000, 120_000]],
                command: ["clip", "split-at", "PKG", "--track", "a", "--track", "b", "--at", "24000", "--at", "120000"]),
            EditRow(
                tool: "clip_paste",
                arguments: ["from": 12_000, "to": 36_000, "track": ["a"], "at": 200_000, "onto": ["b"]],
                command: [
                    "clip", "paste", "PKG", "--from", "12000", "--to", "36000", "--track", "a", "--at", "200000",
                    "--onto",
                    "b",
                ]),
            EditRow(
                tool: "clip_paste", arguments: ["from": 12_000, "to": 36_000, "track": ["a"], "at": 200_000],
                command: ["clip", "paste", "PKG", "--from", "12000", "--to", "36000", "--track", "a", "--at", "200000"]),
            EditRow(
                tool: "clip_paste_clips", arguments: ["clips": ["A"], "at": 200_000, "onto": ["e"]],
                command: ["clip", "paste-clips", "PKG", "A", "--at", "200000", "--onto", "e"]),
            EditRow(
                tool: "clip_duplicate", arguments: ["from": 12_000, "to": 36_000, "track": ["a"]],
                command: ["clip", "duplicate", "PKG", "--from", "12000", "--to", "36000", "--track", "a"]),
            EditRow(
                tool: "clip_duplicate_clips", arguments: ["clips": ["A", "C"]],
                command: ["clip", "duplicate-clips", "PKG", "A", "C"]),
            EditRow(
                tool: "clip_paste_clips", arguments: ["clips": ["A"], "at": 200_000],
                command: ["clip", "paste-clips", "PKG", "A", "--at", "200000"]),
            EditRow(
                tool: "clip_nudge", arguments: ["clips": ["A"], "by": 1000, "lanes": 1],
                command: ["clip", "nudge", "PKG", "A", "--by", "1000", "--lanes", "1"]),
            EditRow(
                tool: "clip_nudge", arguments: ["clips": ["A"], "by": 1000],
                command: ["clip", "nudge", "PKG", "A", "--by", "1000"]),
            EditRow(
                tool: "clip_remove", arguments: ["clips": ["A", "C"]], command: ["clip", "remove", "PKG", "A", "C"]),
            EditRow(tool: "clip_remove", arguments: [:], command: ["clip", "remove", "PKG"]),
            EditRow(
                tool: "clip_move", arguments: ["clip": "A", "track": "e", "start": 5000],
                command: ["clip", "move", "PKG", "A", "--track", "e", "--start", "5000"]),
            EditRow(
                tool: "clip_move", arguments: ["clip": "A", "track": "e", "start": 5000, "mode": "no-overlap"],
                command: ["clip", "move", "PKG", "A", "--track", "e", "--start", "5000", "--mode", "no-overlap"]),
            EditRow(
                tool: "clip_nudge", arguments: ["clips": ["A"], "by": 1000, "mode": "crossfade"],
                command: ["clip", "nudge", "PKG", "A", "--by", "1000", "--mode", "crossfade"]),
            EditRow(
                tool: "clip_shuffle", arguments: ["clip": "A", "track": "e", "start": 5000],
                command: ["clip", "shuffle", "PKG", "A", "--track", "e", "--start", "5000"]),
            EditRow(
                tool: "clip_trim", arguments: ["clip": "A", "from": 1000, "to": 40_000],
                command: ["clip", "trim", "PKG", "A", "--from", "1000", "--to", "40000"]),
            EditRow(
                tool: "clip_gain", arguments: ["clips": ["A", "C"], "db": -6],
                command: ["clip", "gain", "PKG", "A", "C", "--db", "-6"]),
            EditRow(
                tool: "clip_fade", arguments: ["clip": "A", "in": 480, "out": 100],
                command: ["clip", "fade", "PKG", "--clip", "A", "--in", "480", "--out", "100"]),
            EditRow(
                tool: "clip_fade", arguments: ["clip": "A", "in": 480],
                command: ["clip", "fade", "PKG", "--clip", "A", "--in", "480"]),
            EditRow(
                tool: "clip_crossfade", arguments: ["clip": "A2", "length": 960],
                command: ["clip", "crossfade", "PKG", "--clip", "A2", "--length", "960"]),
            EditRow(
                tool: "clip_envelope", arguments: ["clip": "A2", "points": [[96_000, 0], [120_000, -16.5]]],
                command: ["clip", "envelope", "PKG", "A2", "--point", "96000:0", "--point", "120000:-16.5"]),
            EditRow(
                tool: "clip_envelope", arguments: ["clip": "A2", "points": [[Any]]()],
                command: ["clip", "envelope", "PKG", "A2", "--clear"]),
            EditRow(
                tool: "clip_gain_range",
                arguments: ["track": ["a", "b"], "from": 10_000, "to": 100_000, "db": -6, "ramp": 4800],
                command: [
                    "clip", "gain-range", "PKG", "--track", "a", "--track", "b", "--from", "10000", "--to", "100000",
                    "--db", "-6", "--ramp", "4800",
                ]),
            EditRow(
                tool: "clip_gain_range", arguments: ["track": ["a"], "from": 10_000, "to": 100_000, "db": 3],
                command: [
                    "clip", "gain-range", "PKG", "--track", "a", "--from", "10000", "--to", "100000", "--db", "3",
                ]),
            EditRow(
                tool: "clip_close_gaps", arguments: ["clips": ["A", "A2", "A3"]],
                command: ["clip", "close-gaps", "PKG", "A", "A2", "A3"]),
            EditRow(
                tool: "clip_roll", arguments: ["clip": "A2", "by": 960],
                command: ["clip", "roll", "PKG", "A2", "--by", "960"]),
            EditRow(
                tool: "clip_slip", arguments: ["clips": ["A", "C"], "by": 480],
                command: ["clip", "slip", "PKG", "A", "C", "--by", "480"]),
        ]
    }

    static var clipRefusals: [EditRow] {
        [
            EditRow(
                tool: "clip_place", arguments: ["track": "a", "file": "zz", "start": 0, "length": 10],
                command: ["clip", "place", "PKG", "--track", "a", "--file", "zz", "--start", "0", "--length", "10"]),
            EditRow(
                tool: "clip_clear", arguments: ["track": ["zz"], "from": 0, "to": 10],
                command: ["clip", "clear", "PKG", "--track", "zz", "--from", "0", "--to", "10"]),
            EditRow(
                tool: "clip_split", arguments: ["clip": "zz", "at": 1],
                command: ["clip", "split", "PKG", "zz", "--at", "1"]),
            EditRow(
                tool: "clip_split_at", arguments: ["track": ["zz"], "at": [1]],
                command: ["clip", "split-at", "PKG", "--track", "zz", "--at", "1"]),
            EditRow(
                tool: "clip_paste", arguments: ["from": 0, "to": 10, "track": ["zz"], "at": 0],
                command: ["clip", "paste", "PKG", "--from", "0", "--to", "10", "--track", "zz", "--at", "0"]),
            EditRow(
                tool: "clip_paste_clips", arguments: ["clips": ["zz"], "at": 0],
                command: ["clip", "paste-clips", "PKG", "zz", "--at", "0"]),
            EditRow(
                tool: "clip_duplicate", arguments: ["from": 0, "to": 10, "track": ["zz"]],
                command: ["clip", "duplicate", "PKG", "--from", "0", "--to", "10", "--track", "zz"]),
            EditRow(
                tool: "clip_duplicate", arguments: ["from": 100, "to": 100, "track": ["a"]],
                command: ["clip", "duplicate", "PKG", "--from", "100", "--to", "100", "--track", "a"]),
            EditRow(
                tool: "clip_duplicate_clips", arguments: ["clips": ["zz"]],
                command: ["clip", "duplicate-clips", "PKG", "zz"]),
            EditRow(
                tool: "clip_nudge", arguments: ["clips": ["zz"], "by": 1],
                command: ["clip", "nudge", "PKG", "zz", "--by", "1"]),
            EditRow(tool: "clip_remove", arguments: ["clips": ["zz"]], command: ["clip", "remove", "PKG", "zz"]),
            EditRow(
                tool: "clip_move", arguments: ["clip": "zz", "track": "a", "start": 0],
                command: ["clip", "move", "PKG", "zz", "--track", "a", "--start", "0"]),
            EditRow(
                tool: "clip_shuffle", arguments: ["clip": "zz", "track": "a", "start": 0],
                command: ["clip", "shuffle", "PKG", "zz", "--track", "a", "--start", "0"]),
            EditRow(
                tool: "clip_trim", arguments: ["clip": "zz", "from": 0, "to": 10],
                command: ["clip", "trim", "PKG", "zz", "--from", "0", "--to", "10"]),
            EditRow(
                tool: "clip_gain", arguments: ["clips": ["zz"], "db": 0],
                command: ["clip", "gain", "PKG", "zz", "--db", "0"]),
            EditRow(
                tool: "clip_fade", arguments: ["clip": "zz", "in": 1],
                command: ["clip", "fade", "PKG", "--clip", "zz", "--in", "1"]),
            EditRow(
                tool: "clip_crossfade", arguments: ["clip": "A", "length": 2],
                command: ["clip", "crossfade", "PKG", "--clip", "A", "--length", "2"]),
            EditRow(
                tool: "clip_envelope", arguments: ["clip": "A", "points": [[48_000, 0]]],
                command: ["clip", "envelope", "PKG", "A", "--point", "48000:0"]),
            EditRow(
                tool: "clip_gain_range", arguments: ["track": ["zz"], "from": 0, "to": 10, "db": 1],
                command: ["clip", "gain-range", "PKG", "--track", "zz", "--from", "0", "--to", "10", "--db", "1"]),
            EditRow(
                tool: "clip_close_gaps", arguments: ["clips": ["A", "zz"]],
                command: ["clip", "close-gaps", "PKG", "A", "zz"]),
            EditRow(
                tool: "clip_roll", arguments: ["clip": "A", "by": 1],
                command: ["clip", "roll", "PKG", "A", "--by", "1"]),
            EditRow(
                tool: "clip_roll", arguments: ["clip": "A2", "by": 48_000],
                command: ["clip", "roll", "PKG", "A2", "--by", "48000"]),
            EditRow(
                tool: "clip_slip", arguments: ["clips": ["A"], "by": -1],
                command: ["clip", "slip", "PKG", "A", "--by", "-1"]),
        ]
    }
}
