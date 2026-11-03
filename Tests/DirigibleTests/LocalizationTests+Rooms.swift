import AppKit
import DirigibleCore
import Foundation
import Testing

@testable import DirigibleApp

extension LocalizationTests {
    /// The inspector has no spare room: a label is `fixedSize`, and a column takes the width of its
    /// widest label. So a group of texts has a room, which the on-screen check at 240 pt shows
    /// whole. The text of each `AppLanguage` in the group is at most as wide as the room (rounded
    /// up). A text wider than its room needs a shorter value, or that check in its language and a
    /// wider room.
    @Test func eachInspectorTextFitsItsRoom() throws {
        for (name, size, weight, room, keys) in inspectorRooms {
            for language in AppLanguage.allCases.map(\.rawValue) {
                let table = try stringsTable(language)
                for key in keys {
                    let text = try #require(table[key.rawValue], "\(language) \(key.rawValue)")
                    let font = NSFont.systemFont(ofSize: size, weight: weight)
                    let width = NSString(string: text).size(withAttributes: [.font: font]).width.rounded(.up)
                    #expect(width <= room, "\(language) \(key.rawValue): \(width) pt in the room \(room) pt of \(name)")
                }
            }
        }
    }

    /// "Kein Clip verwendet sie" (140.81 pt) shows whole in a 150 pt column, so a cell keeps at least
    /// the column width less 10 pt for its text.
    @Test func eachUnusedFileReasonFitsItsColumn() throws {
        let keys: [L10n] = [
            .sheetUnusedReasonPool, .sheetUnusedReasonStray, .sheetUnusedReasonTranscript, .sheetUnusedReasonCapture,
        ]
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let room = UnusedFilesSheet.reasonWidth - 10
        for language in AppLanguage.allCases.map(\.rawValue) {
            let table = try stringsTable(language)
            for key in keys {
                let text = try #require(table[key.rawValue], "\(language) \(key.rawValue)")
                let width = NSString(string: text).size(withAttributes: [.font: font]).width.rounded(.up)
                #expect(width <= room, "\(language) \(key.rawValue): \(width) pt in the room \(room) pt")
            }
        }
    }
}

/// The inspector text groups: name, font size in pt (11 in the panes, the regular size for the tab
/// picker), weight, room in pt, and keys.
let inspectorRooms: [(name: String, size: Double, weight: NSFont.Weight, room: Double, keys: [L10n])] = [
    ("clip labels", 11, .regular, 50, [.inspectorGain, .inspectorFadeIn, .inspectorFadeOut]),
    ("clip units", 11, .regular, 16, [.inspectorDecibels, .inspectorMilliseconds]),
    ("clip wide label", 11, .regular, 190, [.inspectorGainAtPlayhead, .inspectorEffects, .inspectorEffectNoise]),
    (
        "episode labels", 11, .regular, 59,
        [
            .episodeTitle, .episodeShow, .episodeAuthor, .episodeSeason, .episodeNumber, .episodeDate,
            .episodeLanguage, .episodeCopyright,
        ]
    ),
    ("episode link labels", 11, .regular, 89, [.episodeURL, .episodeFeedURL, .episodeGUID]),
    // The rooms of marker labels, Links, and Choose are the width of the pt-PT text (Hiperligação,
    // Hiperligações, Escolher). The other languages are narrower.
    ("marker labels", 11, .regular, 66, [.markerName, .markerURL]),
    // The heading under the tab picker is the 13 pt semibold system font (P22).
    (
        "tab titles", Double(NSFont.systemFontSize), .semibold, 87,
        [.inspectorTabClip, .inspectorTabEpisode, .inspectorTabMarker, .inspectorTabSilences, .inspectorTabTranscript]
    ),
    ("Explicit", 11, .regular, 45, [.episodeExplicit]),
    ("Links", 11, .regular, 72, [.episodeLinks]),
    ("Choose", 11, .regular, 54, [.episodeArtworkChoose]),
    ("Remove", 11, .regular, 51, [.episodeArtworkRemove]),
    // The empty Transcript tab: the title (P2) is in the title3 style, and its button is a small control.
    (
        "empty title", Double(NSFont.preferredFont(forTextStyle: .title3).pointSize), .regular, 144,
        [.transcriptEmptyTitle]
    ),
    ("Import Transcript", 11, .regular, 136, [.menuFileImportTranscript]),
    // The Follow Playhead check box of the pane header (P18), a small control.
    ("Follow Playhead", 11, .regular, 117, [.transcriptFollow]),
    // The Silences tab: the setting labels share one column, and Scan, Scan Again, and Apply are
    // small buttons in 216 pt.
    ("silences labels", 11, .regular, 95, [.silencesThreshold, .silencesMinimum, .silencesKeep]),
    ("silences buttons", 11, .regular, 90, [.silencesScan, .silencesScanAgain, .silencesApply]),
]
