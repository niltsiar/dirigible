import DirigibleAudio
import DirigibleCore
import Foundation

private let importSource = Param.required(
    "source", "The absolute path of the session package to import from.", .string)
private let importOffset = Param.defaulted(
    "at", "The offset of the source timeline, in frames of this session. A negative offset drops the source head.",
    .integer(), 0)
private let importMarkers = Param.defaulted(
    "markers", "Also import the markers and chapters, with no chapter image.", .boolean, false)

/// The session import (decision 0075).
let sessionImportTools = [
    Tool(
        "import_session",
        "Import the tracks of another session package, as dirigible import-session: each source track becomes a "
            + "new last track with its clips at their positions plus at, and each file that a clip names is copied "
            + "into Clips/ under a new file ID. A track name that is taken gets the source session name, a track "
            + "with an app route imports muted, and the source does not change. The text is the new track IDs, one "
            + "per line." + editCancelNote("no track is added"),
        [importSource, importOffset, importMarkers], batch: .alone
    ) { a throws(ToolError) in
        let (source, at, markers) = (try a[importSource], try a[importOffset], try a[importMarkers])
        guard source.hasPrefix("/") else { throw ToolError("The argument \"source\" must be an absolute path.") }
        return .importSession(ImportSessionWork(source: source, at: at, markers: markers))
    }
]
