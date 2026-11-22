import ArgumentParser
import DirigibleAudio
import DirigibleCore
import DirigibleMCP
import Foundation

struct BinCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bin", abstract: "List, change, and paste the clip bins of the session.",
        discussion: """
            A bin is a named list of items. An item keeps a range of tracks or whole clips with their gain, \
            fades, envelope, and ride, and their audio files stay in the package while an item uses them. A \
            name has no tab and no line break, and the spaces at each end are removed. Exit 1, with no change, \
            for an unknown bin or item, a name of only spaces, or a place that is not in the list.
            """,
        subcommands: [
            ListBins.self, AddBin.self, RenameBin.self, MoveBin.self, RemoveBin.self, AddItem.self, RenameItem.self,
            RemoveItem.self, PasteItem.self,
        ])

    struct ListBins: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list", abstract: "List the bins and their items.",
            discussion: """
                One line bin <id> "<name>" for each bin, in list order, then one line \
                item <id> "<name>" <range|clips> length <frames> tracks <ids> for each of its items. \
                "No bins." when the session has none.
                """)
        @OptionGroup var package: PackageArgument

        func run() throws { print(BinWork.list(try readPackage(package))) }
    }

    struct AddBin: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "add", abstract: "Add a bin at the end of the list. Write the new bin ID.")
        @OptionGroup var package: PackageArgument
        @Argument(help: "The bin name.") var name: String

        func run() throws {
            print(
                try editPackage(package, ripple: false) { session throws(SessionError) in
                    try session.addBin(named: name)
                })
        }
    }

    struct RenameBin: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "rename", abstract: "Rename a bin.")
        @OptionGroup var package: PackageArgument
        @Argument(help: "The bin ID.") var bin: String
        @Argument(help: "The new name.") var name: String

        func run() throws {
            try editPackage(package, ripple: false) { session throws(SessionError) in
                try session.renameBin(BinID(bin), to: name)
            }
        }
    }

    struct MoveBin: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "move", abstract: "Move a bin to a place in the list.")
        @OptionGroup var package: PackageArgument
        @Argument(help: "The bin ID.") var bin: String
        @Option(parsing: .unconditional, help: "The place of the bin in the list after the move, from 0.")
        var index: Int

        func run() throws {
            try editPackage(package, ripple: false) { session throws(SessionError) in
                try session.moveBin(BinID(bin), to: index)
            }
        }
    }

    struct RemoveBin: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "remove", abstract: "Remove a bin and its items.")
        @OptionGroup var package: PackageArgument
        @Argument(help: "The bin ID.") var bin: String

        func run() throws {
            try editPackage(package, ripple: false) { session throws(SessionError) in try session.removeBin(BinID(bin))
            }
        }
    }

    struct AddItem: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "item-add",
            abstract: "Add a range of tracks or whole clips to a bin as a new item. Write the new item ID.",
            discussion: """
                Give --from, --to, and --track for a range, or --clip for whole clips with their time and \
                track offsets. The item keeps the clips with their gain, fades, envelope, and ride. Exit 64 \
                for both forms or for neither.
                """)
        @OptionGroup var package: PackageArgument
        @Argument(help: "The bin ID.") var bin: String
        @Argument(help: "The item name.") var name: String
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
            let edit = BinWork.addItem(try selection(), named: name, to: bin)
            for id in try editPackage(package, ripple: false, edit) { print(id) }
        }
    }

    struct RenameItem: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "item-rename", abstract: "Rename a bin item.")
        @OptionGroup var package: PackageArgument
        @Argument(help: "The item ID.") var item: String
        @Argument(help: "The new name.") var name: String

        func run() throws {
            try editPackage(package, ripple: false) { session throws(SessionError) in
                try session.renameItem(BinItemID(item), to: name)
            }
        }
    }

    struct RemoveItem: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "item-remove", abstract: "Remove a bin item.")
        @OptionGroup var package: PackageArgument
        @Argument(help: "The item ID.") var item: String

        func run() throws {
            try editPackage(package, ripple: false) { session throws(SessionError) in
                try session.removeItem(BinItemID(item))
            }
        }
    }

    struct PasteItem: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "paste",
            abstract: "Paste a bin item at a frame over the clips there. Write the pasted IDs.",
            discussion: """
                The paste gives the clips of a Copy and Paste of the item source. With --insert, the later \
                audio of all tracks moves first by the item length, and a split take refuses it (exit 3). \
                The clips go to the source tracks of the item, or to --onto.
                """)
        @OptionGroup var package: PackageArgument
        @Argument(help: "The item ID.") var item: String
        @Option(parsing: .unconditional, help: "The timeline frame of the paste.") var at: Int
        @Flag(help: "Move the later audio of all tracks by the item length first.") var insert = false
        @Option(help: "A target track for each track of the item, in order. The default is the source tracks.")
        var onto: [String] = []
        @Option(help: SourceOption.help) var source: String?

        func validate() throws { try SourceOption.validate(source, package: package, onto: onto) }

        func run() throws {
            let mode: PasteMode = insert ? .insert(at: Frames(at)) : .over(at: Frames(at))
            if let source {
                let work = PasteWork(
                    source: URL(filePath: source), selection: .binItem(BinItemID(item)), mode: mode, onto: onto)
                return try SourceOption.run(work, package: package)
            }
            let pasted = try editPackage(
                package, ripple: RippleNeed { _ in mode.ripples }, BinWork.paste(item, mode: mode, onto: onto))
            for id in pasted { print(id) }
        }
    }
}
