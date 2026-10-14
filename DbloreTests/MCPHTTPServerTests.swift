// MCPHTTPServerTests.swift
// The MCP server end to end through `MCPServerController`: the real listener, JSON-RPC layer
// and tool service on a free loopback port (refusals, initialize, tools/list, tools/call), and
// the lifecycle driven by the settings (enable, port change, disable, port in use, token
// regenerate). Settings live in a throwaway suite; the token store is in memory.

import Foundation
import Testing

@testable import Dblore

private struct Reply: Sendable {
  let status: Int
  let body: Data
  var json: [String: Any]? { try? JSONSerialization.jsonObject(with: body) as? [String: Any] }
}

/// Holds `loadOrCreate` at a gate so a regenerate can land while the first load is pending.
private final class GatedTokenStore: MCPTokenStore, @unchecked Sendable {
  let gate = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var token = "stored"
  private var loading = false

  var isLoading: Bool { lock.withLock { loading } }

  func loadOrCreate() -> String {
    let stored = lock.withLock {
      loading = true
      return token
    }
    gate.wait()
    return stored
  }

  func regenerate() -> String {
    lock.withLock {
      token = "regenerated"
      return token
    }
  }
}

@MainActor
@Suite("MCP HTTP server", .serialized)
struct MCPHTTPServerTests {
  private let suiteName = "MCPHTTPServerTests.\(UUID().uuidString)"

  private func makeSettings() throws -> AppSettings {
    AppSettings(defaults: try #require(UserDefaults(suiteName: suiteName)))
  }

  private func makeController(
    _ settings: AppSettings, entries: [ConnectionHistoryEntry] = []
  ) -> MCPServerController {
    MCPServerController(
      settings: settings, tokens: InMemoryMCPTokenStore(), savedConnections: { entries },
      password: { _ in nil }, recorder: InMemoryQueryHistoryRecorder())
  }

  /// A port nothing listens on right now.
  private func freePort() async throws -> Int {
    let probe = MCPHTTPServer { _ in .text(200, "") }
    let port = try await probe.start(.init(port: 0, token: "probe"))
    await probe.stop()
    return port
  }

  /// A host stall can hold the main actor for a long time, so waits and requests get 120 s.
  private static let stallTolerance: Duration = .seconds(120)

  /// Waits on the status changes (no polling) until `expected` holds or the deadline passes.
  private func waitFor(
    _ controller: MCPServerController, _ expected: (MCPServerController.Status) -> Bool
  ) async throws {
    let deadline = ContinuousClock.now + Self.stallTolerance
    while ContinuousClock.now < deadline {
      // Reading inside the tracking subscribes before the check, so no change is missed
      let (changes, continuation) = AsyncStream<Void>.makeStream()
      let current = withObservationTracking {
        controller.status
      } onChange: {
        continuation.finish()
      }
      if expected(current) { break }
      let timer = Task {
        try? await ContinuousClock().sleep(until: deadline)
        continuation.finish()
      }
      for await _ in changes {}
      timer.cancel()
    }
    #expect(expected(controller.status), "status: \(controller.status)")
  }

  private func post(
    _ port: Int, _ body: String, token: String?, origin: String? = nil
  ) async throws -> Reply {
    var request = URLRequest(url: try #require(URL(string: "http://127.0.0.1:\(port)/mcp")))
    request.httpMethod = "POST"
    request.httpBody = Data(body.utf8)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
    if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
    let timeout = TimeInterval(Self.stallTolerance.components.seconds)
    request.timeoutInterval = timeout
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = timeout
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let (data, response) = try await session.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
    return Reply(status: status, body: data)
  }

  private func rpc(_ method: String, id: Int, params: String) -> String {
    #"{"jsonrpc":"2.0","id":\#(id),"method":"\#(method)","params":\#(params)}"#
  }

  @Test("End to end: 401 without token, 403 bad Origin, initialize, tools/list, tools/call")
  func endToEnd() async throws {
    let settings = try makeSettings()
    defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
    let entry = ConnectionHistoryEntry(
      config: ConnectionConfig(
        databaseType: .postgresql, host: "db.internal", port: 5432, database: "app",
        username: "u", name: "Orders"))
    settings.mcpAllowedConnectionIDs = [entry.id]
    settings.mcpPort = try await freePort()
    settings.mcpEnabled = true
    let controller = makeController(settings, entries: [entry])
    controller.activate()
    try await waitFor(controller) { $0 == .running(port: settings.mcpPort) }
    let port = settings.mcpPort
    let token = await controller.token()

    let ping = rpc("ping", id: 1, params: "{}")
    #expect(try await post(port, ping, token: nil).status == 401)
    #expect(try await post(port, ping, token: "wrong").status == 401)
    #expect(try await post(port, ping, token: token, origin: "http://evil.com").status == 403)

    let initialize = try await post(
      port,
      rpc(
        "initialize", id: 2,
        params: #"{"protocolVersion":"2025-06-18","capabilities":{},"#
          + #""clientInfo":{"name":"test","version":"1"}}"#), token: token)
    #expect(initialize.status == 200)
    let initialized = try #require(initialize.json?["result"] as? [String: Any])
    #expect(initialized["protocolVersion"] as? String == "2025-06-18")

    let list = try await post(port, rpc("tools/list", id: 3, params: "{}"), token: token)
    let tools = try #require((list.json?["result"] as? [String: Any])?["tools"] as? [[String: Any]])
    #expect(
      Set(tools.compactMap { $0["name"] as? String }) == Set(MCPToolService.tools.map(\.name)))

    let call = try await post(
      port, rpc("tools/call", id: 4, params: #"{"name":"list_connections","arguments":{}}"#),
      token: token)
    let result = try #require(call.json?["result"] as? [String: Any])
    let text = try #require((result["content"] as? [[String: Any]])?.first?["text"] as? String)
    #expect(result["isError"] as? Bool != true)
    #expect(text.contains(entry.id.uuidString))
    #expect(text.contains("Orders"))

    await controller.stop()
    #expect(controller.status == .stopped)
  }

  @Test("Lifecycle: enable runs, port change restarts, regenerate restarts, disable stops")
  func lifecycle() async throws {
    let settings = try makeSettings()
    defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
    settings.mcpPort = try await freePort()
    let controller = makeController(settings)
    controller.activate()
    #expect(controller.status == .stopped)

    settings.mcpEnabled = true
    try await waitFor(controller) { $0 == .running(port: settings.mcpPort) }
    let first = settings.mcpPort
    let oldToken = await controller.token()
    #expect(try await post(first, rpc("ping", id: 1, params: "{}"), token: oldToken).status == 200)

    let second = try await freePort()
    settings.mcpPort = second
    try await waitFor(controller) { $0 == .running(port: second) }
    await #expect(throws: (any Error).self) {
      try await post(first, rpc("ping", id: 1, params: "{}"), token: oldToken)
    }

    await controller.regenerateToken()
    try await waitFor(controller) { $0 == .running(port: second) }
    let newToken = await controller.token()
    #expect(newToken != oldToken)
    let ping = rpc("ping", id: 1, params: "{}")
    #expect(try await post(second, ping, token: oldToken).status == 401)
    #expect(try await post(second, ping, token: newToken).status == 200)

    settings.mcpEnabled = false
    try await waitFor(controller) { $0 == .stopped }
    await #expect(throws: (any Error).self) { try await post(second, ping, token: newToken) }
  }

  @Test("Removing a connection from the allowlist closes its pooled session")
  func allowlistRemovalClosesSession() async throws {
    // run_query posts a History change; the gate keeps it from reloading another test's list
    await LocalDataNotificationGate.shared.acquire()
    defer { LocalDataNotificationGate.shared.release() }
    let settings = try makeSettings()
    defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
    let entry = ConnectionHistoryEntry(
      config: ConnectionConfig(
        databaseType: .postgresql, host: "fake", port: 1, database: "db", username: "u",
        sslMode: .disable, name: "Fake"))
    let factory = FakeDatabaseSessionFactory(capabilities: .contract())
    settings.mcpAllowedConnectionIDs = [entry.id]
    settings.mcpPort = try await freePort()
    settings.mcpEnabled = true
    let controller = MCPServerController(
      settings: settings, tokens: InMemoryMCPTokenStore(), savedConnections: { [entry] },
      password: { _ in nil }, recorder: InMemoryQueryHistoryRecorder(), sessionFactory: factory)
    controller.activate()
    try await waitFor(controller) { $0 == .running(port: settings.mcpPort) }
    let call = rpc(
      "tools/call", id: 1,
      params: #"{"name":"run_query","arguments":{"connection_id":"\#(entry.id.uuidString)","#
        + #""sql":"SELECT 1"}}"#)
    _ = try await post(settings.mcpPort, call, token: await controller.token())
    let session = try #require(factory.sessions.first)
    #expect(!session.didClose)

    settings.mcpAllowedConnectionIDs = []
    let deadline = ContinuousClock.now + .seconds(5)
    while !session.didClose, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(session.didClose)
    await controller.stop()
  }

  @Test("A token regenerated during the first load is kept")
  func regenerateDuringFirstLoad() async throws {
    let settings = try makeSettings()
    defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
    let store = GatedTokenStore()
    let controller = MCPServerController(
      settings: settings, tokens: store, savedConnections: { [] }, password: { _ in nil },
      recorder: InMemoryQueryHistoryRecorder())
    let first = Task { await controller.token() }
    let deadline = ContinuousClock.now + .seconds(5)
    while !store.isLoading, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    await controller.regenerateToken()
    store.gate.signal()
    #expect(await first.value == "regenerated")
    #expect(await controller.token() == "regenerated")
  }

  @Test("A port in use fails with a message, then runs once the port is changed")
  func portInUse() async throws {
    let settings = try makeSettings()
    defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
    let blocker = MCPHTTPServer { _ in .text(200, "") }
    let taken = try await blocker.start(.init(port: 0, token: "other"))
    settings.mcpPort = taken
    settings.mcpEnabled = true
    let controller = makeController(settings)
    controller.activate()
    try await waitFor(controller) {
      if case .failed(let message) = $0 { return !message.isEmpty }
      return false
    }

    let free = try await freePort()
    settings.mcpPort = free
    try await waitFor(controller) { $0 == .running(port: free) }
    await controller.stop()
    await blocker.stop()
  }
}
