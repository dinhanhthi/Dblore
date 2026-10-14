// MCPSettingsModelTests.swift
// Settings > MCP without the view: the allowlist toggles write the setting (DuckDB never), a
// committed port is clamped and the running server moves to it, and the copy buttons put the
// client snippets with the token on the pasteboard without logging the token.

import Foundation
import Testing

@testable import Dblore

@MainActor
@Suite("MCP settings model", .serialized)
struct MCPSettingsModelTests {
  private let suiteName = "MCPSettingsModelTests.\(UUID().uuidString)"
  private let postgres = ConnectionHistoryEntry(
    config: ConnectionConfig(databaseType: .postgresql, database: "app", name: "Orders"))
  private let duckdb = ConnectionHistoryEntry(
    config: ConnectionConfig(databaseType: .duckdb, database: "/tmp/a.duckdb"))

  private func makeSettings() throws -> AppSettings {
    AppSettings(defaults: try #require(UserDefaults(suiteName: suiteName)))
  }

  private func makeModel(
    _ settings: AppSettings, copied: @escaping @MainActor (String) -> Void = { _ in }
  ) -> (MCPSettingsModel, MCPServerController) {
    let entries = [postgres, duckdb]
    let controller = MCPServerController(
      settings: settings, tokens: InMemoryMCPTokenStore(), savedConnections: { entries },
      password: { _ in nil }, recorder: InMemoryQueryHistoryRecorder())
    let model = MCPSettingsModel(
      settings: settings, controller: controller, loadConnections: { entries }, copy: copied)
    return (model, controller)
  }

  private func freePort() async throws -> Int {
    let probe = MCPHTTPServer { _ in .text(200, "") }
    let port = try await probe.start(.init(port: 0, token: "probe"))
    await probe.stop()
    return port
  }

  @Test("Allowlist toggles write the setting; DuckDB is listed but never allowed")
  func allowlist() throws {
    let settings = try makeSettings()
    defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
    let (model, _) = makeModel(settings)
    model.load()
    #expect(model.connections.map(\.id) == [postgres.id, duckdb.id])

    model.setAllowed(postgres.id, true)
    #expect(settings.mcpAllowedConnectionIDs == [postgres.id])
    #expect(model.isAllowed(postgres.id))
    #expect(!MCPSettingsModel.isAvailable(duckdb))
    model.setAllowed(duckdb.id, true)
    #expect(settings.mcpAllowedConnectionIDs == [postgres.id])

    model.setAllowed(postgres.id, false)
    #expect(settings.mcpAllowedConnectionIDs.isEmpty)
  }

  @Test("A committed port is clamped and the running server moves to it")
  func portCommit() async throws {
    let settings = try makeSettings()
    defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
    settings.mcpPort = try await freePort()
    settings.mcpEnabled = true
    let (model, controller) = makeModel(settings)
    controller.activate()
    try await waitFor(controller, .running(port: settings.mcpPort))

    model.portDraft = 80
    model.commitPort()
    #expect(settings.mcpPort == AppSettings.mcpPortRange.lowerBound)
    #expect(model.portDraft == AppSettings.mcpPortRange.lowerBound)

    let next = try await freePort()
    model.portDraft = next
    model.commitPort()
    #expect(settings.mcpPort == next)
    try await waitFor(controller, .running(port: next))
    await controller.stop()
  }

  @Test("Copy puts the snippets with the token on the pasteboard and never logs the token")
  func copy() async throws {
    let settings = try makeSettings()
    defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
    var pasted: [String] = []
    let (model, controller) = makeModel(settings) { pasted.append($0) }
    let token = await controller.token()

    await model.copy(.claudeCode)
    #expect(model.copied == .claudeCode)
    await model.copy(.cursor)
    #expect(model.copied == .cursor)
    #expect(
      pasted == [
        MCPClientConfigSnippet.claudeCodeCommand(port: settings.mcpPort, token: token),
        MCPClientConfigSnippet.cursorJSON(port: settings.mcpPort, token: token),
      ])

    await model.regenerateToken()
    #expect(model.didRegenerate)
    let fresh = await controller.token()
    #expect(fresh != token)
    let logs = await AppLogger.shared.getAllLogs()
    #expect(!logs.contains { $0.message.contains(token) || $0.message.contains(fresh) })
  }

  private func waitFor(
    _ controller: MCPServerController, _ expected: MCPServerController.Status
  ) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while controller.status != expected, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(controller.status == expected)
  }
}
