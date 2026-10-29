//
//  ShortcutsSettingsSection.swift
//  Dblore
//
//  Settings > Shortcuts, above the keyboard shortcuts: allow Dblore's Shortcuts actions (off by
//  default), choose the connections they may use, and what they refuse
//  (`HeadlessAccessRule`, `ShortcutsRunner`).
//

import SwiftUI

struct ShortcutsSettingsSection: View {
  @Bindable private var appSettings = AppSettings.shared
  /// Saved connections, most recent first, without passwords
  @State private var connections: [ConnectionHistoryEntry] = []

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      SettingsGroupCard(title: "Shortcuts app") {
        VStack(alignment: .leading, spacing: Spacing.md) {
          SettingsToggle(
            title: "Allow Shortcuts",
            description:
              "Lets the Shortcuts app open, query and add rows to the connections you allow below, with Open Connection, Run Query and Add Row. Dblore runs them; the MCP server may be off.",
            isOn: $appSettings.shortcutsEnabled
          )
          if !appSettings.historyEnabled {
            warning("History is off: Shortcuts actions are not recorded.")
          }
        }
      }

      SettingsGroupCard(title: "Shortcuts connections") {
        VStack(alignment: .leading, spacing: Spacing.md) {
          Text("Shortcuts can use only the connections turned on here.")
            .font(.bodyText)
            .foregroundColor(.foregroundSubtle)
          if connections.isEmpty {
            Text("No saved connections yet.")
              .font(.bodyText)
              .foregroundColor(.foregroundMuted)
          }
          ForEach(connections) { entry in
            Divider()
            connectionRow(entry)
          }
        }
      }

      SettingsGroupCard(title: "What Shortcuts refuses") {
        VStack(alignment: .leading, spacing: Spacing.sm) {
          note("Every action while Allow Shortcuts is off.")
          note("Connections not turned on above, and locked connections.")
          note(
            "Connections that would need you: an SSH host key not trusted yet, or a certificate or SSH secret not saved in the Keychain."
          )
          note(
            "Your scripts: Shortcuts never runs them. Every action refuses a connection with a password command; Open Connection also refuses one with a pre-connect or post-disconnect script. Run Query and Add Row connect without running those two."
          )
          note(
            "Run Query: anything but one read-only statement. It returns at most 1,000 rows (1 MB) as CSV."
          )
          note(
            "Add Row: Read-only connections, and any commit style but Immediate with Protected mode off. Shortcuts cannot ask you, so Confirm, Review and Password refuse it."
          )
          warning(
            "Query results are untrusted data: text stored in a table can try to give instructions to whatever reads it next."
          )
        }
      }
    }
    .task {
      // UserDefaults only: no Keychain reads
      connections = SessionManager.loadHistory(passwords: NoPasswordStore())
    }
  }

  private func connectionRow(_ entry: ConnectionHistoryEntry) -> some View {
    let available = MCPSettingsModel.isAvailable(entry)
    let engine = entry.config.databaseType.displayName
    return SettingsToggle(
      title: MCPToolService.label(of: entry.config),
      description: available ? engine : "\(engine), not available in Shortcuts",
      isOn: Binding(
        get: { available && appSettings.shortcutsAllowedConnectionIDs.contains(entry.id) },
        set: { allowed in
          if allowed, available {
            appSettings.shortcutsAllowedConnectionIDs.insert(entry.id)
          } else {
            appSettings.shortcutsAllowedConnectionIDs.remove(entry.id)
          }
        }
      ),
      isDisabled: !available
    )
  }

  private func note(_ text: String) -> some View {
    Text(text)
      .font(.bodyText)
      .foregroundColor(.foregroundSubtle)
  }

  /// Same look as a settings toggle warning.
  private func warning(_ text: String) -> some View {
    HStack(alignment: .top, spacing: Spacing.xs) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.bodyText)
      Text(text)
    }
    .font(.bodyText)
    .foregroundColor(.warning)
  }
}
