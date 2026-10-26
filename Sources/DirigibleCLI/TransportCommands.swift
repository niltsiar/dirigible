import ArgumentParser
import DirigibleCore
import DirigibleMCP
import Foundation

/// The commands of the transport tools. They need the running app: each one sends its call to the
/// app socket, as `dirigible mcp` does, and with no app it gives the files text and exits 1.
struct TransportGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transport", abstract: "Play, stop, and locate in the window of a session in the app.",
        subcommands: [TransportPlay.self, TransportStop.self, TransportLocate.self])
}

/// Sends the call of `tool` for `package` to the app, and prints the reply: stdout and exit 0, or
/// `Error: <text>` and exit 1. The app matches the package by its absolute path, so a relative
/// path resolves against the working folder first.
private func sendTransport(_ tool: String, _ package: PackageArgument, _ arguments: [String: Any] = [:]) throws {
    let path = URL(filePath: package.path, relativeTo: .currentDirectory()).standardizedFileURL.path
    let (text, isError) = MCPServer.run(
        tool: tool, ["package": path].merging(arguments) { $1 }, client: ClientInfo(name: "dirigible"),
        route: AgentBridge().route)
    guard !isError else { throw fail(text, code: editRefused) }
    print(text)
}

private func requireFrame(_ value: Int?, _ option: String) throws {
    guard let value else { return }
    guard (0...Frames.limit.count).contains(value) else {
        throw ValidationError("--\(option) must be in 0...\(Frames.limit.count).")
    }
}

struct TransportPlay: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "play",
        abstract: "Play the window of a session forward at 1x, and stop at --to.",
        discussion: """
            The command needs the app with the package open and Let Agents Edit Open Sessions on. With \
            no --from, the play starts at the playhead. With no --to, it stops at the end of the session. \
            During a forward 1x play, a call with neither changes nothing and writes the end of the \
            running play. A locate or a click before --to keeps it; one at or after --to plays on to the \
            end of the session. Space, Stop and Return, J, K, L, and a speed change drop --to. After \
            the play, the playhead stays where the play stopped, and the next take starts there. It writes the state after the call, for example Playing from 24000 to 50000. Exit 1 when the \
            app refuses (a take, a busy window, a start at or after the end, or an engine fault) or is \
            not there. Exit 64 when --to is not more than --from, or a frame is not in 0...2^40.
            """)

    @OptionGroup var package: PackageArgument
    @Option(parsing: .unconditional, help: "The timeline frame where the play starts.") var from: Int?
    @Option(parsing: .unconditional, help: "The timeline frame where the play stops.") var to: Int?

    func validate() throws {
        try requireFrame(from, "from")
        try requireFrame(to, "to")
        if let from, let to, to <= from { throw ValidationError("--to must be more than --from.") }
    }

    func run() throws {
        var arguments: [String: Any] = [:]
        if let from { arguments["from"] = from }
        if let to { arguments["to"] = to }
        try sendTransport("transport_play", package, arguments)
    }
}

struct TransportStop: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Stop the play of the window of a session.",
        discussion: """
            The command needs the app with the package open and Let Agents Edit Open Sessions on. It \
            writes Stopped at <frame>. With nothing playing, it changes nothing. It never stops a \
            take: during a take it exits 1.
            """)

    @OptionGroup var package: PackageArgument

    func run() throws { try sendTransport("transport_stop", package) }
}

struct TransportLocate: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "locate",
        abstract: "Move the playhead of the window of a session to a frame.",
        discussion: """
            The command needs the app with the package open and Let Agents Edit Open Sessions on. A \
            play goes on from the frame. In a play with --to, a frame before --to keeps it, and a \
            frame at or after --to plays on to the end of the session. During a forward play, a frame \
            at or after the end of the session stops it there. The next take starts at the playhead. It writes the state after the call. Exit 1 when the \
            app refuses or is not there. Exit 64 when the frame is not in 0...2^40.
            """)

    @OptionGroup var package: PackageArgument
    @Argument(help: "The timeline frame of the playhead.") var frame: Int

    func validate() throws { try requireFrame(frame, "frame") }

    func run() throws { try sendTransport("transport_locate", package, ["at": frame]) }
}
