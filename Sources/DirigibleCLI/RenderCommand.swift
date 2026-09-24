import ArgumentParser
import DirigibleAudio
import DirigibleCore
import Foundation

struct Render: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Render the session mix to a 32-bit float stereo CAF file at the session rate.",
        discussion: """
            Exit 2 when the package cannot be read, the output path exists, or the write fails; a failed \
            render leaves no output file. A missing or short audio file renders as silence, with one warning \
            line on stderr, and exit 0.
            """)

    @OptionGroup var package: PackageArgument
    @Option(help: "The output file. It must not exist.") var out: String
    @Option(parsing: .unconditional, help: "The first frame. The default is 0.") var from = 0
    @Option(parsing: .unconditional, help: "The frame after the last frame. The default is the session end.")
    var to: Int?

    func run() throws {
        let session = try readPackage(package)
        let end = to ?? session.end.count
        guard from >= 0, end > from, end <= Frames.limit.count else {
            throw ValidationError(
                "The range must be 0 or more, with --to more than --from; the session end is \(session.end).")
        }
        let output = URL(filePath: out)
        // Control-C: remove the temporary file, then exit as the default action does.
        signal(SIGINT, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        interrupt.setEventHandler {
            removeRenderLeftovers(of: output)
            Foundation.exit(128 + SIGINT)
        }
        interrupt.resume()
        defer { interrupt.cancel() }
        let faults: [FileID: MediaFault]
        do {
            faults = try renderMix(session, package: package.url, range: Frames(from)..<Frames(end), to: output)
        } catch .exists {
            throw fail("\(out) exists.", code: packageError)
        } catch .writeFailed(let status) {
            throw fail("cannot write \(out) (status \(status)).", code: packageError)
        } catch .moveFailed(let code) {
            throw fail("cannot move the render to \(out): \(String(cString: strerror(code))).", code: packageError)
        }
        for (id, fault) in faults.sorted(by: { $0.key < $1.key }) {
            let path = session.files[id].map { String(reflecting: $0.path) } ?? "?"
            FileHandle.standardError.write(
                Data("Warning: file \(id) \(path) \(describe(fault)); its clips render as silence.\n".utf8))
        }
    }
}

/// The media state of a file in words: "is missing", "has 5000 frames", or "cannot be read".
private func describe(_ fault: MediaFault) -> String {
    switch fault {
    case .missing: "is missing"
    case .short(let frames): "has only \(frames) frames"
    case .unreadable: "cannot be read"
    }
}
