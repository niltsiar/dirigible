import AppKit
import DirigibleMCP
import SwiftUI

/// An MCP client of the Copy Setup Command pull-down (C13). The texts come from
/// `docs/research/mcp-clients.md`.
enum SetupClient: CaseIterable, Sendable {
    case claudeCode, codex, opencode, anyApp

    /// The item title: a product name, or "Any MCP App" in the app language.
    var title: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .opencode: "opencode"
        case .anyApp: L10n.settingsAgentsAnyApp.text
        }
    }
}

/// The registration text of `client` for the `dirigible` helper of the app at `bundle`. Nil for an
/// app in App Translocation or on a `readOnly` volume (a mounted disk image): that path is gone
/// after the next launch. With `DIRIGIBLE_MCP_SOCKET` set (the verify copy), the server gets the
/// same socket.
func setupCommand(_ client: SetupClient, bundle: URL, readOnly: Bool, environment: [String: String]) -> String? {
    guard !readOnly, !bundle.path.contains("/AppTranslocation/") else { return nil }
    var server = quoted(bundle.appending(path: "Contents/Helpers/dirigible").path) + " mcp"
    if let socket = environment["DIRIGIBLE_MCP_SOCKET"], !socket.isEmpty {
        server = "env " + quoted("DIRIGIBLE_MCP_SOCKET=" + socket) + " " + server
    }
    switch client {
    case .claudeCode: return "claude mcp add --scope user dirigible -- " + server
    case .codex: return "codex mcp add dirigible -- " + server
    case .opencode: return "opencode mcp add dirigible -- " + server
    case .anyApp: return server
    }
}

/// `text` in single quotes for a POSIX shell: each `'` becomes `'\''`.
private func quoted(_ text: String) -> String {
    "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
}

/// The agent part of Settings (ui-panel.md): the switch, its help line, and the setup pull-down.
struct AgentSettingsView: View {
    let app: AppDelegate
    @State private var on: Bool
    @State private var copied = false

    init(app: AppDelegate) {
        self.app = app
        _on = State(initialValue: app.agentsOn)
    }

    var body: some View {
        Toggle(L10n.settingsAgents.key, isOn: $on).toggleStyle(.switch)
            .onChange(of: on) { _, new in app.setAgents(new) }
        Text(help.key).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        let commands = SetupClient.allCases.compactMap(command)
        if commands.isEmpty {
            Text(L10n.settingsAgentsMoveFirst.key).font(.callout).foregroundStyle(.secondary)
        } else {
            Menu {
                ForEach(commands, id: \.title) { item in Button(item.title) { copy(item.text) } }
            } label: {
                // A fixed width, so the label change after a copy does not move the layout.
                Group {
                    if copied {
                        Label(L10n.settingsAgentsCopied.key, systemImage: "checkmark")
                    } else {
                        Text(L10n.settingsAgentsCopy.key)
                    }
                }
                .frame(width: 220)
            }
            .fixedSize()
            Text(L10n.settingsAgentsCopyHint.key).font(.callout).foregroundStyle(.secondary)
        }
    }

    private var help: L10n {
        switch app.agents.state {
        case .servedElsewhere: .settingsAgentsElsewhere
        case .failed: .settingsAgentsFailed
        case .listening: .settingsAgentsOn
        case .off: on ? .settingsAgentsOn : .settingsAgentsOff
        }
    }

    /// Read once: the volume of a running app does not change.
    private static let bundleReadOnly =
        (try? Bundle.main.bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false

    private func command(_ client: SetupClient) -> (title: String, text: String)? {
        setupCommand(
            client, bundle: Bundle.main.bundleURL, readOnly: Self.bundleReadOnly,
            environment: ProcessInfo.processInfo.environment
        )
        .map { (client.title, $0) }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        postAnnouncement(L10n.settingsAgentsCopied.text, priority: .high)
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}
