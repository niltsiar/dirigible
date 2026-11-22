import DirigibleAudio
import DirigibleCore
import Foundation

/// The tools of `dirigible bin` (F22): the bins of a session and their items. Each edit runs the edit
/// of its command: under the lock on the files, and as one undo step in the app. A bin edit is not a
/// batch step.
private let binID = Param.required("bin", "The bin ID.", .string)
private let itemID = Param.required("item", "The bin item ID.", .string)
private let binName = Param.required(
    "name", "The name: no tab and no line break. The spaces at each end are removed; a name of only spaces is refused.",
    .string)
private let binIndex = Param.required(
    "index", "The place of the bin in the list after the move, from 0.", .integer())
private let rangeFrom = Param<Int?>.optional(
    "from", "The first frame of a range. Give it with to and track.", .integer())
private let rangeTo = Param<Int?>.optional("to", "The frame after the last frame of the range.", .integer())
private let rangeTracks = Param.defaulted(
    "track", "The tracks of the range: one or more. Not with clips.", .strings(), [String]())
private let itemClips = Param.defaulted(
    "clips", "Whole clips with their time and track offsets, in place of a range.", .strings(), [String]())
private let pasteAt = Param.required("at", "The timeline frame of the paste.", .integer())
private let pasteInsert = Param.defaulted(
    "insert", "Insert: first move the later audio of all tracks by the item length.", .boolean, false)

let binTools = [
    Tool(
        "bin_list",
        "List the bins of the session, in order, as dirigible bin list: a line bin <id> \"<name>\" for each bin, "
            + "then a line item <id> \"<name>\" <range|clips> length <frames> tracks <ids> for each of its items. "
            + "No bins. when the session has none.",
        [], saves: false, batch: .alone
    ) { _ throws(ToolError) in .bins }.hinted(.readOnly),
    Tool(
        "bin_add", "Add a bin at the end of the list, as dirigible bin add. Give the new bin ID.", [binName],
        batch: .alone
    ) { a throws(ToolError) in
        let name = try a[binName]
        let id = BinID()
        return .edit(ripple: false) { session throws(SessionError) in
            [try session.addBin(id, named: name).rawValue]
        }
    },
    Tool("bin_rename", "Rename a bin, as dirigible bin rename.", [binID, binName], batch: .alone) {
        a throws(ToolError) in
        let (bin, name) = (BinID(try a[binID]), try a[binName])
        return .edit(ripple: false) { session throws(SessionError) in
            try session.renameBin(bin, to: name)
            return []
        }
    },
    Tool("bin_move", "Move a bin to a place in the list, as dirigible bin move.", [binID, binIndex], batch: .alone) {
        a throws(ToolError) in
        let (bin, index) = (BinID(try a[binID]), try a[binIndex])
        return .edit(ripple: false) { session throws(SessionError) in
            try session.moveBin(bin, to: index)
            return []
        }
    },
    Tool("bin_remove", "Remove a bin and its items, as dirigible bin remove.", [binID], batch: .alone) {
        a throws(ToolError) in
        let bin = BinID(try a[binID])
        return .edit(ripple: false) { session throws(SessionError) in
            try session.removeBin(bin)
            return []
        }
    },
    Tool(
        "bin_item_add",
        "Add a range of tracks (from, to, and track) or whole clips (clips) to a bin as a new item, as dirigible "
            + "bin item-add. The item keeps the clips with their gain, fades, envelope, and ride, and their audio "
            + "files stay in the package while an item uses them. Give the new item ID.",
        [binID, binName, rangeFrom, rangeTo, rangeTracks, itemClips], batch: .alone
    ) { a throws(ToolError) in
        let (bin, name) = (try a[binID], try a[binName])
        let selection = try BinWork.selection(
            from: try a[rangeFrom], to: try a[rangeTo], tracks: try a[rangeTracks], clips: try a[itemClips],
            spelling: .tool)
        return .edit(ripple: false, BinWork.addItem(selection, named: name, to: bin))
    },
    Tool("bin_item_rename", "Rename a bin item, as dirigible bin item-rename.", [itemID, binName], batch: .alone) {
        a throws(ToolError) in
        let (item, name) = (BinItemID(try a[itemID]), try a[binName])
        return .edit(ripple: false) { session throws(SessionError) in
            try session.renameItem(item, to: name)
            return []
        }
    },
    Tool("bin_item_remove", "Remove a bin item, as dirigible bin item-remove.", [itemID], batch: .alone) {
        a throws(ToolError) in
        let item = BinItemID(try a[itemID])
        return .edit(ripple: false) { session throws(SessionError) in
            try session.removeItem(item)
            return []
        }
    },
    Tool(
        "bin_paste",
        "Paste a bin item at a frame over the clips there, as dirigible bin paste: the same clips as a Copy and "
            + "Paste of the item source. With insert, the later audio of all tracks moves first by the item length. "
            + "The clips go to the source tracks of the item, or to onto. Give the pasted IDs."
            + Arg.pasteSourceNote,
        [itemID, pasteAt, pasteInsert, Arg.pasteOnto, Arg.pasteSource], batch: .alone
    ) { a throws(ToolError) in
        let (item, frame, onto) = (try a[itemID], Frames(try a[pasteAt]), try a[Arg.pasteOnto])
        let mode: PasteMode = try a[pasteInsert] ? .insert(at: frame) : .over(at: frame)
        if let work = try a.paste(.binItem(BinItemID(item)), mode: mode, onto: onto) { return .paste(work) }
        return .edit(ripple: RippleNeed { _ in mode.ripples }, BinWork.paste(item, mode: mode, onto: onto))
    },
]
