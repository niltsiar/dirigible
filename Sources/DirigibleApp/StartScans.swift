import Foundation

/// The first free name ("Episode N" with no package of that name) and the Finder names of the
/// folder and its parent. It reads the file system, so it runs off the main actor.
@concurrent nonisolated func scanFolder(
    _ folder: URL, format: @Sendable (Int) -> String, exists: @Sendable (URL) -> Bool
) async -> FolderScan {
    var number = 1
    while exists(folder.appending(path: "\(format(number)).dirigible")) { number += 1 }
    let names = [folder.deletingLastPathComponent(), folder].map { FileManager.default.displayName(atPath: $0.path) }
    return FolderScan(folder: folder, name: format(number), text: names.joined(separator: " › "))
}

/// Checks that each recent package exists. It reads the file system, so it runs off the main
/// actor.
@concurrent nonisolated func scanRecent(_ urls: [URL], exists: @Sendable (URL) -> Bool) async -> [RecentRow] {
    urls.map { RecentRow(url: $0, exists: exists($0)) }
}

/// Makes the folder, one level only, when it is missing. A failure shows later as the error of
/// the Create.
@concurrent nonisolated func makeFolder(_ folder: URL, exists: @Sendable (URL) -> Bool) async {
    guard !exists(folder) else { return }
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
}
