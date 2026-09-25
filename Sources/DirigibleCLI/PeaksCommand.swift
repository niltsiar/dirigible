import ArgumentParser
import DirigibleAudio
import DirigibleCore
import Foundation

/// `dirigible peaks`: the peak cache state of each pool file (decisions 0011 and 0017).
struct PeaksCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "peaks",
        abstract: "Show the peak cache state of each audio file of a session package.",
        discussion: """
            One line for each audio file, in ID order: the path, a tab, and "hit <bins>", "miss", or \
            "missing". It writes nothing, takes no lock, and computes no peaks. Exit 2 when the package \
            cannot be read.
            """)

    @OptionGroup var package: PackageArgument
    @Option(help: "The peak cache folder. The default is the folder of the app.") var cache: String?

    func run() throws {
        let session = try readPackage(package)
        let folder = cache.map { URL(filePath: $0) } ?? PeakFile.folder
        let states: [(path: String, state: PeakCacheState)]
        do {
            states = try peakCacheStates(of: session, package: package.url, cache: folder)
        } catch {
            throw fail("cannot check the audio files: \(error.localizedDescription)", code: packageError)
        }
        for (path, state) in states {
            switch state {
            case .hit(let bins): print("\(path)\thit \(bins)")
            case .miss: print("\(path)\tmiss")
            case .missing: print("\(path)\tmissing")
            }
        }
    }
}
