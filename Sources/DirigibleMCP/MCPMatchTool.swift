import DirigibleCore
import Foundation

private let tracks = Param.required("tracks", "The track IDs: one or more.", .strings(minItems: 1))
private let reference = Param<String?>.optional(
    "reference",
    "The clip ID of the reference voice. It makes a new match on each track, or replaces the old one.", .string)
private let from = Param<Int?>.optional(
    "from", "With reference: the first timeline frame of the part of the reference clip to learn. Give it with to.",
    .integer())
private let to = Param<Int?>.optional(
    "to", "With reference: the timeline frame after that part. Give it with from.", .integer())
private let amount = Param<Int?>.optional(
    "amount",
    "The amount in whole percent, 1 to 100. A new match takes 75; a replace keeps the amount of its track.",
    .integer())
private let bypass = Param<Bool?>.optional(
    "bypass", "true plays the track with no match, false plays it with the match. Not with reference.", .boolean)
private let remove = Param.defaulted("remove", "Remove the match of the tracks.", .boolean, false)

/// `track_match_voice` (decision 0074). Its own file because `MCPToolTable.swift` is near its size
/// limit.
let matchTools = [
    Tool(
        "track_match_voice",
        "Match the voice of tracks to a reference voice, as dirigible track match-voice. With reference (and "
            + "optionally from and to), it reads the reference clip and each track, and gives each track a live "
            + "EQ curve that moves its spectrum toward the reference. It changes no audio file. Each side needs "
            + "10 s of voice. Music and effects tracks are left out. With amount, bypass, or both (no "
            + "reference), it changes the match of tracks that have one; with remove, the match goes. Give one line "
            + "for each track: \"<track>: match <amount> % (+<boost> dB, -<cut> dB)\" with \", bypassed\" after it "
            + "for a bypassed match, \"<track>: left out, a music or effects track\", \"<track>: match removed\", "
            + "or \"<track>: no match\"."
            + editCancelNote("no track changes"),
        [tracks, reference, from, to, amount, bypass, remove], batch: .step
    ) { a throws(ToolError) in
        let parsed = MatchWork.parse(
            tracks: try a[tracks], reference: try a[reference], from: try a[from], to: try a[to],
            amount: try a[amount], bypass: try a[bypass], remove: try a[remove])
        switch parsed {
        case .failure(let error): throw error
        case .success(let work):
            switch work.mode {
            case .set(let request): return .matchVoice(work, request)
            case .edit(let edit):
                return .edit(ripple: false) { session throws(SessionError) in try work.edit(edit, &session) }
            }
        }
    }
]
