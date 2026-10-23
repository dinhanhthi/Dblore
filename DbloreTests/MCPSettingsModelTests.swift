// MCPSettingsModelTests.swift
// Settings > MCP without the view: the allowlist toggles write the setting (DuckDB never,
// MongoDB allowed), write tools are off and every connection Read by default and in old
// settings, a committed port is clamped and the running server moves to it, and the copy
// buttons put the client snippets with the token on the pasteboard without logging the token.
// The server denies the waiting write approvals of a connection whose scope narrows to Read,
// and all of them when write tools are turned off, the token is regenerated or MCP is disabled.

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
  private let mongo = ConnectionHistoryEntry(
    config: ConnectionConfig(databaseType: .mongodb, database: "app"))

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

  @Test("Allowlist toggles write the setting; DuckDB is never allowed, MongoDB is")
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
    #expect(MCPSettingsModel.isAvailable(mongo))
    model.setAllowed(duckdb.id, true)
    #expect(settings.mcpAllowedConnectionIDs == [postgres.id])

    model.setAllowed(postgres.id, false)
    #expect(settings.mcpAllowedConnectionIDs.isEmpty)
  }

  @Test("Write tools are off and every connection is Read by default and in old settings")
  func writeScopesDefaultToRead() throws {
    defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
    let fresh = try makeSettings()
    #expect(!fresh.mcpWriteToolsEnabled)
    #expect(fresh.mcpWriteScopes.isEmpty)

    // Settings saved before write scopes: an allowlist only. An unknown or malformed stored
    // scope never widens either.
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.set([postgres.id.uuidString], forKey: "app.settings.mcpAllowedConnectionIDs")
    defaults.set(
      [mongo.id.uuidString: "everything", "not-a-uuid": MCPWriteScope.schema.rawValue],
      forKey: "app.settings.mcpWriteScopes")
    let old = AppSettings(defaults: defaults)
    #expect(!old.mcpWriteToolsEnabled)
    #expect(old.mcpAllowedConnectionIDs == [postgres.id])
    #expect(old.mcpWriteScopes.isEmpty)
    let (model, _) = makeModel(old)
    model.load()
    #expect(model.scope(for: postgres.id) == .read)

    // A scope set here is kept only while the connection stays allowlisted
    model.setScope(.data, for: postgres.id)
    #expect(AppSettings(defaults: defaults).mcpWriteScopes == [postgres.id: .data])
    model.setAllowed(postgres.id, false)
    model.setAllowed(postgres.id, true)
    #expect(model.scope(for: postgres.id) == .read)
    model.setScope(.schema, for: duckdb.id)
    #expect(model.scope(for: duckdb.id) == .read)
  }

  @Test("Waiting approvals are denied on a narrowed scope, write tools off, new token, MCP off")
  func narrowedSettingsDenyWaitingApprovals() async throws {
    let settings = try makeSettings()
    defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
    let other = UUID()
    settings.mcpPort = try await freePort()
    settings.mcpEnabled = true
    settings.mcpAllowedConnectionIDs = [postgres.id, other]
    settings.mcpWriteToolsEnabled = true
    settings.mcpWriteScopes = [postgres.id: .data, other: .data]
    let center = MCPWriteApprovalCenter(timeout: .seconds(30), approveDelay: .zero)
    let controller = MCPServerController(
      settings: settings, tokens: InMemoryMCPTokenStore(), savedConnections: { [] },
      password: { _ in nil }, recorder: InMemoryQueryHistoryRecorder(), approver: center)
    controller.activate()
    defer { Task { await controller.stop() } }
    try await waitFor(controller, .running(port: settings.mcpPort))
    let request = { (id: UUID) in
      MCPWriteApprovalRequest(
        connectionID: id, clientName: "agent", connectionName: "Orders", engine: "PostgreSQL",
        statement: "DELETE FROM t WHERE id = 1", classification: "Data modification",
        warnings: [])
    }
    let waiting = [postgres.id, other].map { id in Task { try await center.request(request(id)) } }
    try await waitUntil { center.queue.count == 2 }

    settings.mcpWriteScopes = [postgres.id: .read, other: .data]
    #expect(try await !waiting[0].value)
    #expect(center.queue.map(\.connectionID) == [other])
    settings.mcpWriteToolsEnabled = false
    #expect(try await !waiting[1].value)
    #expect(center.queue.isEmpty)

    // A new token or MCP turned off: no request of the old server stays answerable
    settings.mcpWriteToolsEnabled = true
    for revoke in [
      { await controller.regenerateToken() }, { settings.mcpEnabled = false },
    ] as [@MainActor () async -> Void] {
      let pending = Task { try await center.request(request(other)) }
      try await waitUntil { center.queue.count == 1 }
      await revoke()
      // Denied at once, well before the 30 s timeout
      try await waitUntil { center.queue.isEmpty }
      #expect(try await !pending.value)
    }
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition(), ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    try #require(condition())
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
