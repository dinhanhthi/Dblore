// MCPSettingsModel.swift
// Settings > MCP: the allowlist of saved connections, the write scope of each allowlisted one
// (Read unless set; removing a connection from the allowlist drops its scope), the port
// (applied on commit, so typing never restarts the server), token regenerate and the client
// snippets for the copy buttons. Write scopes never touch the token.
// The command-line tool: a pairing code with its countdown while the server runs, the paired
// tools with revoke, and the pair and install lines for the copy buttons.
// The token and the paired tools are read off the main actor and never logged.

import AppKit
import Foundation
import Observation

@MainActor @Observable
final class MCPSettingsModel {
  enum Snippet: Equatable {
    case claudeCode
    case cursor
    case pairCommand
    case installCommand
  }

  /// Saved connections, most recent first, without passwords
  private(set) var connections: [ConnectionHistoryEntry] = []
  /// The port field; written to the settings by `commitPort`
  var portDraft: Int
  /// The snippet waiting for the token
  private(set) var copying: Snippet?
  /// The snippet just copied, cleared after a moment (the button reads "Copied")
  private(set) var copied: Snippet?
  private(set) var isRegenerating = false
  /// Set once a new token is made: copied commands hold the old one
  private(set) var didRegenerate = false
  /// The pairing code shown; cleared once it is used, burned or expired, or the server stops
  private(set) var pairingCode: MCPCLIPairingCode?
  /// Time left on `pairingCode`, mm:ss
  private(set) var pairingCountdown = ""
  /// Paired command-line tools, oldest first; nil until read
  private(set) var pairedTools: [MCPCLICredential]?
  /// Set when a revoke could not delete the Keychain item
  private(set) var revokeError: String?

  let settings: AppSettings
  let controller: MCPServerController
  @ObservationIgnored private let loadConnections: @MainActor () -> [ConnectionHistoryEntry]
  @ObservationIgnored private let copyToPasteboard: @MainActor (String) -> Void
  @ObservationIgnored private let pairing: MCPCLIPairingService
  /// Bumped by every read of the paired tools and every revoke: only the latest read is shown
  @ObservationIgnored private var pairedLoads = 0

  init(
    settings: AppSettings = .shared,
    controller: MCPServerController = .shared,
    loadConnections: @escaping @MainActor () -> [ConnectionHistoryEntry] = {
      // UserDefaults only: no Keychain reads
      SessionManager.loadHistory(passwords: NoPasswordStore())
    },
    copy: @escaping @MainActor (String) -> Void = { text in
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
      // Clipboard-history apps skip concealed items, so the token is not kept there
      NSPasteboard.general.setString(
        "", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
    },
    pairing: MCPCLIPairingService = .shared
  ) {
    self.settings = settings
    self.controller = controller
    self.loadConnections = loadConnections
    self.copyToPasteboard = copy
    self.pairing = pairing
    portDraft = settings.mcpPort
  }

  /// DuckDB has no read-only second instance in the same process, so MCP refuses it.
  static func isAvailable(_ entry: ConnectionHistoryEntry) -> Bool {
    entry.config.databaseType != .duckdb
  }

  /// The saved connections, and the pairing code still waiting when Settings reopens.
  func load() {
    connections = loadConnections()
    pairingCode = pairing.activeCode
  }

  func isAllowed(_ id: UUID) -> Bool {
    settings.mcpAllowedConnectionIDs.contains(id)
  }

  func setAllowed(_ id: UUID, _ allowed: Bool) {
    if allowed {
      guard let entry = connections.first(where: { $0.id == id }), Self.isAvailable(entry)
      else { return }
      settings.mcpAllowedConnectionIDs.insert(id)
    } else {
      settings.mcpAllowedConnectionIDs.remove(id)
      settings.mcpWriteScopes[id] = nil
    }
  }

  /// `.read` unless the connection is allowlisted and was given a write scope.
  func scope(for id: UUID) -> MCPWriteScope {
    guard isAllowed(id) else { return .read }
    return settings.mcpWriteScopes[id] ?? .read
  }

  /// Sets an allowlisted connection's write scope; others stay Read.
  func setScope(_ scope: MCPWriteScope, for id: UUID) {
    guard isAllowed(id) else { return }
    settings.mcpWriteScopes[id] = scope == .read ? nil : scope
  }

  /// Applies the port field (clamped by the settings); a running server restarts on it.
  func commitPort() {
    if portDraft != settings.mcpPort { settings.mcpPort = portDraft }
    portDraft = settings.mcpPort
  }

  /// Copies a client snippet for the port the server runs on (else the saved one), the pair line
  /// of the code shown or the install line.
  func copy(_ snippet: Snippet) async {
    switch snippet {
    case .claudeCode, .cursor:
      copying = snippet
      let token = await controller.token()
      copying = nil
      let port: Int
      if case .running(let running) = controller.status {
        port = running
      } else {
        port = settings.mcpPort
      }
      copyToPasteboard(
        snippet == .claudeCode
          ? MCPClientConfigSnippet.claudeCodeCommand(port: port, token: token)
          : MCPClientConfigSnippet.cursorJSON(port: port, token: token))
    case .pairCommand:
      guard let pairingCode else { return }
      copyToPasteboard(Self.pairCommand(pairingCode))
    case .installCommand:
      copyToPasteboard(Self.installCommand(appPath: Bundle.main.bundlePath))
    }
    copied = snippet
    Task {
      try? await Task.sleep(for: .seconds(1.5))
      if copied == snippet { copied = nil }
    }
  }

  func regenerateToken() async {
    isRegenerating = true
    await controller.regenerateToken()
    isRegenerating = false
    didRegenerate = true
  }

  // MARK: - Command-line tool

  /// Shows a new code for the running server (any shown code ends). No Keychain access.
  func startPairing() {
    guard case .running(let port) = controller.status else { return }
    let code = pairing.start(port: port)
    pairingCode = code
    pairingCountdown = Self.countdown(code.expires - .now)
  }

  /// The view's task while a code is shown: the countdown once a second, until the code is no
  /// longer active (used, burned, expired or ended with the server). The code is cleared then
  /// and the paired tools read again, since a used code is a new tool.
  func followPairing() async {
    while let shown = pairingCode {
      guard pairing.activeCode == shown else {
        pairingCode = nil
        Task { await loadPairedTools() }
        return
      }
      pairingCountdown = Self.countdown(shown.expires - .now)
      guard (try? await Task.sleep(for: .seconds(1))) != nil else { return }
    }
  }

  /// Reads the paired tools off the main actor.
  func loadPairedTools() async {
    pairedLoads += 1
    let load = pairedLoads
    let pairing = self.pairing
    let tools = await Task.detached { pairing.list() }.value
    guard load == pairedLoads else { return }
    pairedTools = tools.sorted { $0.date < $1.date }
  }

  /// The row goes at once; the token is refused before the Keychain item is deleted.
  func revoke(id: String) async {
    pairedLoads += 1
    revokeError = nil
    pairedTools?.removeAll { $0.id == id }
    let pairing = self.pairing
    if await !Task.detached(operation: { pairing.revoke(id: id) }).value {
      revokeError =
        "The tool is refused now, but its Keychain item could not be deleted, so it works again "
        + "after the MCP server restarts. Try Revoke again."
    }
    await loadPairedTools()
  }

  /// mm:ss, rounded up so a valid code never reads 00:00
  nonisolated static func countdown(_ remaining: Duration) -> String {
    let (seconds, attoseconds) = remaining.components
    let total = max(0, Int(seconds) + (attoseconds > 0 ? 1 : 0))
    return String(format: "%02d:%02d", total / 60, total % 60)
  }

  nonisolated static func pairCommand(_ code: MCPCLIPairingCode) -> String {
    "dblore pair \(code.code) --port \(code.port)"
  }

  /// Links the tool in the app bundle into /usr/local/bin. The path sits in double quotes, so
  /// the characters the shell still reads there are escaped.
  nonisolated static func installCommand(appPath: String) -> String {
    let quoted = appPath.reduce(into: "") { text, character in
      if "\\\"$`".contains(character) { text.append("\\") }
      text.append(character)
    }
    return "sudo mkdir -p /usr/local/bin && sudo ln -sf \"\(quoted)/Contents/Helpers/dblore\" "
      + "/usr/local/bin/dblore"
  }
}
