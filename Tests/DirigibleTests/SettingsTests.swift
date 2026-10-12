import Foundation
import Testing

@testable import DirigibleApp
@testable import DirigibleMCP

/// The agent part of Settings (decision 0046, criteria C1 and C13 of run 2026-10-12-mcp-in-app):
/// the switch and the setup commands.
@MainActor struct SettingsTests {
    /// C1: with no stored value, the app does not listen; the switch starts and stops the server
    /// and stores the choice.
    @Test func agentServerIsOffByDefault() throws {
        let domain = "DirigibleTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let socket = shortSocket()
        defer { try? FileManager.default.removeItem(at: socket.deletingLastPathComponent()) }
        let app = AppDelegate(recordings: nil, defaults: defaults, agentSocket: socket)

        app.startAgentsIfOn()
        #expect(app.agents.state == .off)
        #expect(!FileManager.default.fileExists(atPath: socket.path))

        app.setAgents(true)
        #expect(app.agents.state == .listening)
        #expect(defaults.bool(forKey: AppDelegate.agentsKey))
        #expect(FileManager.default.fileExists(atPath: socket.path))

        app.setAgents(false)
        #expect(app.agents.state == .off)
        #expect(!defaults.bool(forKey: AppDelegate.agentsKey))
    }

    /// C13: each item copies the registration text of its client, with the helper path in single
    /// quotes; a `'` in the path is written as `'\''`.
    @Test(arguments: [
        (
            SetupClient.claudeCode, "/Applications/Dirigible.app",
            "claude mcp add --scope user dirigible -- '/Applications/Dirigible.app/Contents/Helpers/dirigible' mcp"
        ),
        (
            .codex, "/Applications/Dirigible.app",
            "codex mcp add dirigible -- '/Applications/Dirigible.app/Contents/Helpers/dirigible' mcp"
        ),
        (
            .opencode, "/Applications/Dirigible.app",
            "opencode mcp add dirigible -- '/Applications/Dirigible.app/Contents/Helpers/dirigible' mcp"
        ),
        (.anyApp, "/Applications/Dirigible.app", "'/Applications/Dirigible.app/Contents/Helpers/dirigible' mcp"),
        (
            .anyApp, "/Applications/My Apps/Dirigible.app",
            "'/Applications/My Apps/Dirigible.app/Contents/Helpers/dirigible' mcp"
        ),
        (
            .anyApp, "/Applications/Bo's/Dirigible.app",
            #"'/Applications/Bo'\''s/Dirigible.app/Contents/Helpers/dirigible' mcp"#
        ),
    ])
    func setupCommandOfEachClient(client: SetupClient, bundle: String, text: String) {
        #expect(setupCommand(client, bundle: URL(filePath: bundle), environment: [:]) == text)
    }

    /// C13: the verify copy sets `DIRIGIBLE_MCP_SOCKET` for the server, so the copied text reaches
    /// the copy and not the installed app.
    @Test func setupCommandKeepsTheSocketOfTheCopy() {
        let text = setupCommand(
            .codex, bundle: URL(filePath: "/tmp/v/Dirigible.app"),
            environment: ["DIRIGIBLE_MCP_SOCKET": "/tmp/v/mcp.sock"])
        #expect(
            text == "codex mcp add dirigible -- env 'DIRIGIBLE_MCP_SOCKET=/tmp/v/mcp.sock' "
                + "'/tmp/v/Dirigible.app/Contents/Helpers/dirigible' mcp")
    }

    /// C13: an app in App Translocation or on a disk image copies nothing.
    @Test func translocatedAppCopiesNothing() {
        let translocated = "/private/var/folders/x/T/AppTranslocation/1234/d/Dirigible.app"
        for bundle in [translocated, "/Volumes/Dirigible/Dirigible.app"] {
            #expect(setupCommand(.claudeCode, bundle: URL(filePath: bundle), environment: [:]) == nil, "\(bundle)")
        }
        #expect(
            setupCommand(.claudeCode, bundle: URL(filePath: "/Applications/Dirigible.app"), environment: [:]) != nil)
    }

    /// C14: the texts of the Undo item name the agent in both languages.
    @Test func agentUndoTextsInBothLanguages() throws {
        let en = try stringsTable("en")
        let es = try stringsTable("es")
        let name = "Claude Code"
        #expect(String(format: try #require(en[L10n.undoAgent.rawValue]), name) == "Undo Claude Code Edit")
        #expect(String(format: try #require(en[L10n.redoAgent.rawValue]), name) == "Redo Claude Code Edit")
        #expect(
            String(format: try #require(es[L10n.undoAgent.rawValue]), name) == "Deshacer edición de Claude Code")
        #expect(
            String(format: try #require(es[L10n.redoAgent.rawValue]), name) == "Rehacer edición de Claude Code")
    }
}

/// A socket path in a new folder under /tmp: `sun_path` holds 104 bytes, and the temporary
/// folder of the account is longer. The server makes the folder.
func shortSocket() -> URL {
    URL(filePath: "/tmp/dapp-\(UUID().uuidString.prefix(8))/mcp.sock")
}
