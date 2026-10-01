// DatabaseCapabilitiesTests.swift
// DatabaseType.capabilities: PostgreSQL keeps today's features; SQLite is available as beta.

import Foundation
import Testing

@testable import Dblore

@Suite("Database Capabilities")
struct DatabaseCapabilitiesTests {

  @Test("PostgreSQL keeps today's features, reconnect cancel, and still requires a host")
  func postgresqlCapabilities() {
    let capabilities = DatabaseType.postgresql.capabilities
    #expect(capabilities == Self.postgresql)
    // Host stays required: the form gates on usesNetwork, and PostgreSQL uses the network.
    #expect(capabilities.usesNetwork)
  }

  @Test("SQLite is available as beta, without network, password, or SSL")
  func sqliteCapabilities() {
    let capabilities = DatabaseType.sqlite.capabilities
    #expect(capabilities == Self.sqlite)
    #expect(capabilities.isAvailable)
    #expect(!capabilities.usesNetwork)
    #expect(!capabilities.usesPassword)
    #expect(!capabilities.supportsSSL)
  }

  private static let postgresql = DatabaseCapabilities(
    usesNetwork: true,
    usesPassword: true,
    supportsSSL: true,
    supportsSchemas: true,
    supportsRolesAndUsers: true,
    supportsFunctions: true,
    supportsServerCursor: true,
    supportsSessionBrakes: true,
    cancelStrategy: .reconnect,
    cappedReadResetsSession: true,
    supportsExplainJSON: true,
    supportsUpdateOnly: true,
    isAvailable: true
  )

  private static let sqlite = DatabaseCapabilities(
    usesNetwork: false,
    usesPassword: false,
    supportsSSL: false,
    supportsSchemas: false,
    supportsRolesAndUsers: false,
    supportsFunctions: false,
    supportsServerCursor: false,
    supportsSessionBrakes: false,
    cancelStrategy: .interrupt,
    cappedReadResetsSession: false,
    supportsExplainJSON: false,
    supportsUpdateOnly: false,
    isAvailable: true
  )
}
