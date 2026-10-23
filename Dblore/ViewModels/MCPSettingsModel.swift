// MCPSettingsModel.swift
// Settings > MCP: the allowlist of saved connections, the write scope of each allowlisted one
// (Read unless set; removing a connection from the allowlist drops its scope), the port
// (applied on commit, so typing never restarts the server), token regenerate and the client
// snippets for the copy buttons. Write scopes never touch the token.
// The token is read through the controller (off the main actor) and never logged.

import AppKit
import Foundation
import Observation

@MainActor @Observable
final class MCPSettingsModel {
  enum Snippet: Equatable {
    case claudeCode
    case cursor
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

  let settings: AppSettings
  let controller: MCPServerController
  @ObservationIgnored private let loadConnections: @MainActor () -> [ConnectionHistoryEntry]
  @ObservationIgnored private let copyToPasteboard: @MainActor (String) -> Void

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
    }
  ) {
    self.settings = settings
    self.controller = controller
    self.loadConnections = loadConnections
    self.copyToPasteboard = copy
    portDraft = settings.mcpPort
  }

  /// DuckDB has no read-only second instance in the same process, so MCP refuses it.
  static func isAvailable(_ entry: ConnectionHistoryEntry) -> Bool {
    entry.config.databaseType != .duckdb
  }

  func load() {
    connections = loadConnections()
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

  /// Copies a client snippet for the port the server runs on (else the saved one).
  func copy(_ snippet: Snippet) async {
    copying = snippet
    let token = await controller.token()
    copying = nil
    let port: Int
    if case .running(let running) = controller.status {
      port = running
    } else {
      port = settings.mcpPort
    }
    switch snippet {
    case .claudeCode:
      copyToPasteboard(MCPClientConfigSnippet.claudeCodeCommand(port: port, token: token))
    case .cursor:
      copyToPasteboard(MCPClientConfigSnippet.cursorJSON(port: port, token: token))
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
}
