import DirigibleCore
import Foundation

/// Why `openChecked` opened no file.
enum CheckedOpenFault: Error, Hashable {
    case missing
    /// A link at any component of the path, a FIFO, a folder, or another item that is not a file.
    case notRegularFile
    /// The open or the `fstat` fails with another errno.
    case unreadable(Int32)
}

/// The device and inode of a checked file, and its size.
struct CheckedFile: Equatable {
    let device: dev_t
    let inode: ino_t
    let size: Int64

    init(_ info: stat) {
        (device, inode, size) = (info.st_dev, info.st_ino, Int64(info.st_size))
    }
}

/// Opens `path` under `folder` with no link at any component and with no wait on a FIFO, and
/// checks that it is a regular file. The caller closes the descriptor. The template copy and the
/// session import check each source file with it (decisions 0079 and 0075).
func openChecked(_ path: String, in folder: Int32) throws(CheckedOpenFault) -> (
    descriptor: Int32, file: CheckedFile
) {
    let descriptor = openat(folder, path, O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else {
        switch errno {
        case ENOENT: throw .missing
        case ELOOP, ENOTDIR: throw .notRegularFile
        case let code: throw .unreadable(code)
        }
    }
    var info = stat()
    guard fstat(descriptor, &info) == 0 else {
        let code = errno
        close(descriptor)
        throw .unreadable(code)
    }
    guard info.st_mode & S_IFMT == S_IFREG else {
        close(descriptor)
        throw .notRegularFile
    }
    return (descriptor, CheckedFile(info))
}

/// `openChecked` of the pool file at `name`, and of `other` once when `name` is missing: a package
/// job of another process can convert the file after the resolve (decision 0072). Returns the name
/// that it opened.
func openChecked(_ name: PoolFileName, other: PoolFileName?, in folder: Int32) throws(CheckedOpenFault) -> (
    descriptor: Int32, file: CheckedFile, name: PoolFileName
) {
    do throws(CheckedOpenFault) {
        let opened = try openChecked(name.name, in: folder)
        return (opened.descriptor, opened.file, name)
    } catch .missing {
        guard let other else { throw .missing }
        let opened = try openChecked(other.name, in: folder)
        return (opened.descriptor, opened.file, other)
    }
}
