// DatabaseConnectFailureTests.swift
// A failed connect publishes nothing: no connection and no config (so no connected policy).

import Foundation
import Testing

@testable import SQLNotebook

@Suite("Database Connect Failure Tests")
struct DatabaseConnectFailureTests {
  @Test("After a failed connect the actor holds no config and is not connected")
  func failedConnectLeavesNoConfig() async {
    let manager = DatabaseConnectionManager()
    // Non-routable address + 1s timeout: fails fast via the timeout path (no retries)
    let unreachable = ConnectionConfig(
      host: "10.255.255.1", port: 5432, database: "db", username: "user", password: "pw",
      sslMode: .disable, timeoutSeconds: 1, protectionLevel: .readOnly, safeMode: .safeAll)

    await #expect(throws: (any Error).self) {
      try await manager.connect(config: unreachable)
    }
    #expect(await !manager.isConnected)
    #expect(await manager.connectedPolicy.protectionLevel == .none)
    #expect(await manager.databaseType == nil)
  }
}
