//
//  MCPSettingsSection.swift
//  Dblore
//
//  Settings > MCP: run the MCP server, choose the connections agents may use (each Read
//  unless write tools are on and it is given a write scope), copy the client setup for
//  Claude Code or Cursor, pair the dblore command-line tool, and add the outside MCP servers
//  the AI chat may call.
//

import SwiftUI

struct MCPSettingsSection: View {
  @State private var model = MCPSettingsModel()
  @Bindable private var appSettings = AppSettings.shared
  @FocusState private var portFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      SettingsGroupCard(title: "Server") {
        VStack(alignment: .leading, spacing: Spacing.md) {
          SettingsToggle(
            title: "Run the MCP server",
            description:
              "Lets AI agents such as Claude Code and Cursor read the connections you allow below, through a server on 127.0.0.1. Dblore must be running.",
            isOn: $appSettings.mcpEnabled
          )
          Divider()
          portRow
          status
        }
      }

      SettingsGroupCard(title: "Connections") {
        VStack(alignment: .leading, spacing: Spacing.md) {
          VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("Agents can use only the connections turned on here.")
              .font(.bodyText)
              .foregroundColor(.foregroundSubtle)
            warning(
              "Use a least-privilege database user. An agent can read everything the connection's role can read, including other databases on the same server."
            )
          }
          if model.connections.isEmpty {
            Text("No saved connections yet.")
              .font(.bodyText)
              .foregroundColor(.foregroundMuted)
          }
          ForEach(model.connections) { entry in
            Divider()
            connectionRow(entry)
          }
        }
      }

      SettingsGroupCard(title: "Write tools") {
        VStack(alignment: .leading, spacing: Spacing.md) {
          SettingsToggle(
            title: "Allow write tools",
            description:
              "Lets agents ask to run one change at a time on the connections given a write scope above. Every change waits for you to approve it in Dblore; it is denied 2 minutes after it is shown.",
            isOn: $appSettings.mcpWriteToolsEnabled
          )
          warning(
            "Approve only statements you have read. An agent can be steered by text stored in the database."
          )
          Divider()
          note(
            "Changes run with the connection's protection and commit style. Connections that use Review or Password refuse agent changes: set Confirm or Immediate to allow them. A connection without its own commit style uses the default one, so a Review default refuses agent changes too."
          )
          note(
            "Schema changes cover tables, indexes, views, sequences, schemas, types, domains and MySQL databases, TRUNCATE, RENAME TABLE and COMMENT ON; on MongoDB, collections and indexes. Agents cannot create, change or drop functions, procedures or triggers, because what they run later cannot be checked and dropping one removes what it enforces: use the SQL editor. MongoDB system collections and pipelines that name another database are refused."
          )
        }
      }

      SettingsGroupCard(title: "Queries") {
        VStack(alignment: .leading, spacing: Spacing.sm) {
          rowCapRow
          Text(
            "Rows an agent query returns when it does not ask for a number. Between \(AppSettings.mcpRowCapRange.lowerBound) and \(AppSettings.mcpRowCapRange.upperBound)."
          )
          .font(.bodyText)
          .foregroundColor(.foregroundSubtle)
          if !appSettings.historyEnabled {
            warning("History is off: MCP queries are not recorded.")
          }
        }
      }

      SettingsGroupCard(title: "Clients") {
        VStack(alignment: .leading, spacing: Spacing.md) {
          Text(
            "Copies the setup with this Mac's token. Paste the command in a terminal, or the JSON in Cursor's mcp.json."
          )
          .font(.bodyText)
          .foregroundColor(.foregroundSubtle)
          HStack(spacing: Spacing.sm) {
            copyButton(.claudeCode, title: "Copy Claude Code command")
            copyButton(.cursor, title: "Copy Cursor JSON")
          }
          Divider()
          HStack(spacing: Spacing.md) {
            Text("Regenerate token")
              .font(.bodyText)
              .foregroundColor(.foreground)
            Spacer(minLength: Spacing.sm)
            if model.isRegenerating {
              ProgressView().controlSize(.small)
            }
            Button("Regenerate") {
              Task { await model.regenerateToken() }
            }
            .buttonStyle(FilledSecondaryButtonStyle())
            .controlSize(.regular)
            .disabled(model.isRegenerating || model.copying != nil)
            .linkPointer()
          }
          Text(
            model.didRegenerate
              ? "New token created. Copy the command or JSON again for your clients."
              : "Clients that use the old token stop working until you copy the setup again."
          )
          .font(.bodyText)
          .foregroundColor(model.didRegenerate ? .success : .foregroundSubtle)
        }
      }

      commandLineTool

      OutsideMCPServersSection()

      SettingsGroupCard(title: "About MCP") {
        VStack(alignment: .leading, spacing: Spacing.sm) {
          note("Read-only: one statement per query, checked first, then run read-only.")
          note(
            "Write tools are off unless you allow them: each change is checked against its scope, then waits for your approval."
          )
          note("Dblore must be running for agents to connect.")
          note("Agent reads do not see uncommitted changes in Dblore's own open transaction.")
          warning(
            "Query results are sent to the agent. Treat them as untrusted data: text stored in a table can try to give the agent instructions."
          )
        }
      }
    }
    .task {
      model.load()
      await model.loadPairedTools()
    }
    .task(id: model.pairingCode) { await model.followPairing() }
  }

  private var isRunning: Bool {
    if case .running = model.controller.status { return true }
    return false
  }

  private var commandLineTool: some View {
    SettingsGroupCard(title: "Command-line tool") {
      VStack(alignment: .leading, spacing: Spacing.md) {
        note(
          "Lets the dblore command-line tool list and query the connections allowed above from a terminal, read-only. Each pairing has its own token."
        )
        HStack(spacing: Spacing.sm) {
          Button("Pair Command-Line Tool") { model.startPairing() }
            .buttonStyle(PrimaryButtonStyle())
            .controlSize(.regular)
            .disabled(!isRunning)
            .linkPointer()
          Spacer(minLength: 0)
        }
        if !appSettings.mcpEnabled {
          note("Turn the MCP server on to use the command-line tool.")
        }
        if isRunning, let code = model.pairingCode {
          pairingCodeView(code)
        }
        Divider()
        pairedTools
        Divider()
        VStack(alignment: .leading, spacing: Spacing.sm) {
          Text("Install")
            .font(.bodyText)
            .foregroundColor(.foreground)
          note("Links the tool inside Dblore into /usr/local/bin. Asks for your Mac password.")
          commandLine(
            MCPSettingsModel.installCommand(appPath: Bundle.main.bundlePath),
            copy: .installCommand)
        }
      }
    }
  }

  private func pairingCodeView(_ code: MCPCLIPairingCode) -> some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      note("Run this in a terminal:")
      commandLine(MCPSettingsModel.pairCommand(port: code.port), copy: .pairCommand)
      note("Then type this code when it asks (it works once):")
      HStack(alignment: .firstTextBaseline, spacing: Spacing.md) {
        Text(code.code)
          .font(.monoLarge)
          .foregroundColor(.foreground)
          .textSelection(.enabled)
        Spacer(minLength: Spacing.sm)
        Text("Expires in \(model.pairingCountdown)")
          .font(.bodyText)
          .monospacedDigit()
          .foregroundColor(.foregroundSubtle)
      }
    }
  }

  private func commandLine(_ text: String, copy snippet: MCPSettingsModel.Snippet) -> some View {
    HStack(spacing: Spacing.sm) {
      Text(text)
        .font(.monoMedium)
        .foregroundColor(.foreground)
        .lineLimit(1)
        .truncationMode(.middle)
        .textSelection(.enabled)
        .help(text)
      Spacer(minLength: Spacing.sm)
      copyButton(snippet, title: "Copy")
    }
  }

  @ViewBuilder private var pairedTools: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      Text("Paired tools")
        .font(.bodyText)
        .foregroundColor(.foreground)
      if let tools = model.pairedTools {
        if tools.isEmpty {
          Text("No command-line tool is paired.")
            .font(.bodyText)
            .foregroundColor(.foregroundMuted)
        }
        ForEach(tools, id: \.id) { tool in
          pairedToolRow(tool)
        }
        if tools.contains(where: \.isSessionOnly) {
          note(
            "Session only: this build cannot keep pairings in the Keychain, so they end when Dblore quits."
          )
        }
      } else {
        Text("Loading…")
          .font(.bodyText)
          .foregroundColor(.foregroundMuted)
      }
      if let error = model.revokeError {
        warning(error)
      }
    }
  }

  private func pairedToolRow(_ tool: MCPCLICredential) -> some View {
    HStack(spacing: Spacing.md) {
      VStack(alignment: .leading, spacing: Spacing.xs) {
        Text(tool.name)
          .font(.bodyText)
          .foregroundColor(.foreground)
        Text(
          "Paired \(tool.date.formatted(date: .abbreviated, time: .shortened))"
            + (tool.isSessionOnly ? " · Session only" : "")
        )
        .font(.bodyText)
        .foregroundColor(.foregroundSubtle)
      }
      Spacer(minLength: Spacing.sm)
      Button("Revoke") {
        Task { await model.revoke(id: tool.id) }
      }
      .buttonStyle(DangerButtonStyle())
      .controlSize(.regular)
      .linkPointer()
    }
  }

  private var portRow: some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      HStack {
        Text("Port")
          .font(.bodyText)
          .foregroundColor(.foreground)
        Spacer()
        // Committed on Return or focus loss only, so a half-typed port never restarts the server
        TextField(
          "\(AppSettings.defaultMCPPort)", value: $model.portDraft,
          format: .number.grouping(.never)
        )
        .textFieldStyle(.plain)
        .numberInputCapsuleStyle()
        .frame(width: 80)
        .focused($portFocused)
        .onSubmit { model.commitPort() }
        .onChange(of: portFocused) { _, focused in
          if !focused { model.commitPort() }
        }
      }
      Text(
        "Between \(AppSettings.mcpPortRange.lowerBound) and \(AppSettings.mcpPortRange.upperBound). Give clients only the port shown as running."
      )
      .font(.bodyText)
      .foregroundColor(.foregroundSubtle)
    }
  }

  @ViewBuilder
  private var status: some View {
    switch model.controller.status {
    case .stopped:
      statusText("Stopped", color: .foregroundMuted)
    case .starting:
      HStack(spacing: Spacing.sm) {
        ProgressView().controlSize(.small)
        statusText("Starting…", color: .foregroundMuted)
      }
    case .running(let port):
      statusText("Running on \(MCPHTTPServer.host):\(port)", color: .success)
    case .failed(let message):
      statusText(message, color: .destructive)
        .textSelection(.enabled)
    }
  }

  private func statusText(_ text: String, color: Color) -> some View {
    Text(text)
      .font(.bodyText)
      .foregroundColor(color)
  }

  private func connectionRow(_ entry: ConnectionHistoryEntry) -> some View {
    let available = MCPSettingsModel.isAvailable(entry)
    let name =
      entry.config.name.isEmpty
      ? (entry.config.database as NSString).lastPathComponent : entry.config.name
    let engine = entry.config.databaseType.displayName
    return VStack(alignment: .leading, spacing: Spacing.sm) {
      SettingsToggle(
        title: name,
        description: available ? engine : "\(engine), not available over MCP",
        isOn: Binding(
          get: { available && model.isAllowed(entry.id) },
          set: { model.setAllowed(entry.id, $0) }
        ),
        isDisabled: !available
      )
      if available, appSettings.mcpWriteToolsEnabled, model.isAllowed(entry.id) {
        scopeRow(entry.id)
      }
    }
  }

  private func scopeRow(_ id: UUID) -> some View {
    let scope = model.scope(for: id)
    return HStack {
      Text("Agent access")
        .font(.bodyText)
        .foregroundColor(.foregroundSubtle)
      Spacer()
      CapsuleDropdown(
        title: scope.title, accessibilityLabel: "Agent access: \(scope.title)",
        options: MCPWriteScope.allCases, optionTitle: \.title, isSelected: { $0 == scope },
        onSelect: { model.setScope($0, for: id) })
    }
  }

  private var rowCapRow: some View {
    HStack {
      Text("Default row cap")
        .font(.bodyText)
        .foregroundColor(.foreground)
      Spacer()
      HStack(spacing: Spacing.sm) {
        TextField("", value: $appSettings.mcpRowCap, format: .number.grouping(.never))
          .textFieldStyle(.plain)
          .numberInputCapsuleStyle()
          .frame(width: 80)
        Stepper("", value: $appSettings.mcpRowCap, in: AppSettings.mcpRowCapRange)
          .compactStepperStyle()
      }
    }
  }

  private func copyButton(_ snippet: MCPSettingsModel.Snippet, title: String) -> some View {
    Button(model.copied == snippet ? "Copied" : title) {
      Task { await model.copy(snippet) }
    }
    .buttonStyle(FilledSecondaryButtonStyle())
    .controlSize(.regular)
    .disabled(model.copying != nil || model.isRegenerating)
    .linkPointer()
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
