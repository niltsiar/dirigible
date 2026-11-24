import DirigibleAudio
import DirigibleCore
import Foundation

private let capture = Param.required("capture", "The capture ID.", .string)
private let file = Param.required("file", "The file ID.", .string)

/// `capture add` and `file add` have no tool: they write raw clock data and a file record with no
/// audio read (ParityTests.toolExemptions).
let poolTools = [
    Tool("capture_remove", "Remove a capture that no file uses.", [capture], batch: .step) { a throws(ToolError) in
        let id = CaptureID(try a[capture])
        return .edit(ripple: false) { session throws(SessionError) in
            try session.removeCapture(id)
            return []
        }
    },
    Tool("file_remove", "Remove a file that no clip uses.", [file], batch: .step) { a throws(ToolError) in
        let id = FileID(try a[file])
        return .edit(ripple: false) { session throws(SessionError) in
            try session.removeFile(id)
            return []
        }
    },
    Tool(
        "file_prune",
        "Move the clip files that no clip uses to the Trash, as dirigible file prune does. A file that a clip of a "
            + "backup uses stays. The tool cannot see the clipboard of an app window. A package that is open in the app "
            + "is refused: use File > Remove Unused Files there.",
        [dryRun], saves: false, batch: .alone
    ) { a throws(ToolError) in .prune(dryRun: try a[dryRun]) },
    Tool(
        "file_archive",
        "Convert each 24-bit clip WAV to FLAC with the same samples to save disk space, as dirigible file archive "
            + "does. An edit converts the files back first. \(archiveStoreRule) A package that is open in the app is "
            + "refused.",
        [], saves: false, batch: .alone
    ) { _ in .archive(.archive) },
    Tool(
        "file_unarchive",
        "Convert each FLAC clip file back to a WAV, as dirigible file unarchive does. A damaged FLAC stays, and the "
            + "result is then an error that names it. A package that is open in the app is refused.",
        [], saves: false, batch: .alone
    ) { _ in .archive(.unarchive) },
]

private let dryRun = Param.defaulted("dry_run", "Give the list and change nothing.", .boolean, false)

private let backupName = Param.required(
    "name", "The backup file name, as backup_list gives it.",
    Kind(schema: ["type": "string"], expected: backupNameExpected) { ($0 as? String).flatMap(Backup.init(fileName:)) })

/// When a save keeps a backup and how many stay, from `BackupPolicy` (decision 0043), for the two
/// backup tools and for `dirigible backup list --help`.
package let backupRule =
    "Dirigible keeps a backup of session.xml before a save when the newest backup is "
    + "\(RecordRequest.units(BackupPolicy.interval / 60_000, "minute")) old or older, and when the window of the "
    + "session closes. It keeps the \(BackupPolicy.count) newest backups."

let backupTools = [
    Tool(
        "backup_list", "Give the backup file names of the session, newest first. " + backupRule, [], saves: false,
        batch: .alone
    ) { _ in
        .backups
    }.hinted(.readOnly),
    Tool(
        "backup_revert",
        "Revert the session to a backup. It keeps a backup of the replaced session first. " + backupRule,
        [backupName], batch: .alone
    ) { a throws(ToolError) in .revert(try a[backupName]) },
]
