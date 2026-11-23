import ArgumentParser
import DirigibleAudio
import DirigibleCore
import DirigibleMCP
import Foundation

struct FavoritesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "favorites", abstract: "Print the path of the Favorites store, and add clips to it.",
        discussion: """
            The Favorites store is one session package for all sessions, at 48000 Hz, with its own copy of \
            each audio file. Its bins are the favorite groups. DIRIGIBLE_FAVORITES sets another store path. \
            dirigible bin lists, renames, removes, and pastes its items: give it the path that \
            favorites path prints, and --source with that path to paste into another session.
            """,
        subcommands: [StorePath.self, AddFavorite.self])

    struct StorePath: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "path", abstract: "Print the path of the Favorites store.")

        func run() { print(Favorites.package(environment: ProcessInfo.processInfo.environment).path) }
    }

    struct AddFavorite: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "add",
            abstract: "Copy a range or whole clips of a package into the Favorites store. Write the new item ID.",
            discussion: """
                Give --from, --to, and --track for a range, or --clip for whole clips, as bin item-add. Only \
                the audio that the clips play is copied into the store, and converted to 48000 Hz from another \
                rate. The item goes to --bin, else to the first bin; an empty store gets the bin "Favorites". \
                The store and its folders are made when they are missing. The package does not change. Exit 2 \
                while another holder has the store lock.
                """)
        @OptionGroup var package: PackageArgument
        @Argument(help: "The item name.") var name: String
        @Option(help: "The bin ID in the store. The default is the first bin.") var bin: String?
        @Option(parsing: .unconditional, help: "The first frame of the range.") var from: Int?
        @Option(parsing: .unconditional, help: "The frame after the last frame of the range.") var to: Int?
        @Option(help: "A track of the range. Give one or more.") var track: [String] = []
        @Option(help: "A clip to add whole, in place of a range. Give one or more.") var clip: [String] = []

        func validate() throws { _ = try selection() }

        private func selection() throws(ValidationError) -> BinWork.Selection {
            do throws(ToolError) {
                return try BinWork.selection(from: from, to: to, tracks: track, clips: clip, spelling: .cli)
            } catch {
                throw ValidationError(error.message)
            }
        }

        func run() throws {
            let work = FavoritesWork(try selection(), named: name, bin: bin)
            let store = Favorites.package(environment: ProcessInfo.processInfo.environment)
            let journal = FaultJournal()
            defer { journal.quit() }
            do throws(EditFailure<PasteError>) {
                print(try work.run(source: package.url, store: store, log: journal.log))
            } catch {
                throw editExit(error, package: store.path, refused: refusedPaste)
            }
        }
    }
}
