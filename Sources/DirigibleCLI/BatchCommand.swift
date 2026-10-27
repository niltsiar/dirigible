import ArgumentParser
import DirigibleMCP
import Foundation

/// `dirigible batch` (decision 0063): many edit calls as one read-edit-save. It reads the `calls`
/// array of the tool `batch`, checks it with the same code, and runs it with `runOnFiles`.
struct BatchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "batch",
        abstract:
            "Apply \(BatchWork.limit.lowerBound) to \(BatchWork.limit.upperBound) edit calls in one save. If a call fails, the package does not change. Print one line "
            + "for each result line.",
        discussion:
            "The file holds the calls array of the tool batch: [{\"tool\": \"clip_trim\", \"arguments\": "
            + "{\"clip\": \"j1\", \"from\": 0, \"to\": 240000}}]. A call has no package. Exit 64: the file is not "
            + "valid, or a call is not a step. Exit 1: a call is refused. Exit 3: a ripple call on a split take.")
    @OptionGroup var package: PackageArgument
    @Argument(help: "The JSON file with the array of calls, or - for stdin.") var file: String

    func run() throws {
        let data: Data
        do {
            data =
                file == "-" ? FileHandle.standardInput.readDataToEndOfFile() : try Data(contentsOf: URL(filePath: file))
        } catch {
            throw fail("cannot read \(file): \(error.localizedDescription)", code: ExitCode.validationFailure.rawValue)
        }
        let calls: [BatchWork.Call]
        do throws(ToolError) {
            guard let json = try? JSONSerialization.jsonObject(with: data) else {
                throw ToolError("\(file) is not JSON.")
            }
            calls = try BatchWork.parse(json)
        } catch {
            throw fail(error.message, code: ExitCode.validationFailure.rawValue)
        }
        let work: BatchWork
        do throws(BatchWork.CheckFailure) {
            // The checks read an absolute path of the package, as the tool does.
            work = try BatchWork.check(calls, package: package.url.absoluteURL.path)
        } catch {
            throw fail(error.message, code: ExitCode.validationFailure.rawValue)
        }
        do throws(EditFailure<BatchWork.Failure>) {
            print(try work.runOnFiles(package.url).joined(separator: "\n"))
        } catch {
            throw fail(error.message(package: package.path), code: exitCode(of: error))
        }
    }

    /// As `editPackage(refused:)`: a refused call exits 1, a package fault or a pending take 2, a
    /// ripple on a split take 3.
    private func exitCode(of error: EditFailure<BatchWork.Failure>) -> Int32 {
        switch error {
        case .file, .pendingTake: packageError
        case .splitTake: unplacedAudio
        case .body(let failure):
            switch failure.cause {
            case .step: editRefused
            case .rippleBlocked: unplacedAudio
            }
        }
    }
}
