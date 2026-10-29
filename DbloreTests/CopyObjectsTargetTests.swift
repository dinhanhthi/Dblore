// CopyObjectsTargetTests.swift
// The writable Copy Objects target (`makeCopyTargetManager`): a locked row is refused before any
// password is read, Read-only and Schema-only rows before connecting (fake sessions, nothing
// opened), and a SQLite row saved with Protected mode on commits the copy on its own transaction:
// once the manager is closed, a new connection reads the rows (real SQLite file in the temporary
// folder, no server).

import Foundation
import Testing
import os

@testable import Dblore

@Suite("Copy Objects target")
struct CopyObjectsTargetTests {
  @Test("A locked target is refused before any Keychain read")
  func lockedRefusedBeforeKeychain() async throws {
    let registry = LockRegistry()
    let config = Self.postgres(level: .none)
    registry.setLockedConnections([LockIdentity(config)])
    let reads = OSAllocatedUnfairLock(initialState: 0)
    let factory = FakeDatabaseSessionFactory(capabilities: DatabaseType.postgresql.capabilities)
    do {
      _ = try await DatabaseConnectionManager.makeCopyTargetManager(
        config: config,
        password: { _ in
          reads.withLock { $0 += 1 }
          return "secret"
        },
        makeManager: { DatabaseConnectionManager(sessionFactory: factory, lockSource: registry) })
      Issue.record("Expected connectionLocked")
    } catch DatabaseError.connectionLocked {
      // Refused before the password was read
    }
    #expect(reads.withLock { $0 } == 0)
    #expect(factory.sessions.isEmpty)
  }

  @Test(
    "Read-only and Schema-only targets are refused before connecting",
    arguments: [
      (ConnectionProtectionLevel.readOnly, CopyObjectsTargetError.readOnly),
      (.schemaOnly, .schemaOnly),
    ])
  func protectedLevelsRefused(
    level: ConnectionProtectionLevel, expected: CopyObjectsTargetError
  ) async throws {
    let reads = OSAllocatedUnfairLock(initialState: 0)
    let factory = FakeDatabaseSessionFactory(capabilities: DatabaseType.postgresql.capabilities)
    do {
      _ = try await DatabaseConnectionManager.makeCopyTargetManager(
        config: Self.postgres(level: level),
        password: { _ in
          reads.withLock { $0 += 1 }
          return "secret"
        },
        makeManager: {
          DatabaseConnectionManager(sessionFactory: factory, lockSource: LockRegistry())
        })
      Issue.record("Expected \(expected)")
    } catch let error as CopyObjectsTargetError {
      #expect(error == expected)
    }
    #expect(reads.withLock { $0 } == 0)
    #expect(factory.sessions.isEmpty)
  }

  @Test("A SQLite target saved with Protected mode on keeps the copied rows after its close")
  @MainActor
  func protectedModeTargetCommits() async throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("dblore-copy-target-\(UUID().uuidString).sqlite")
    defer {
      for suffix in ["", "-wal", "-shm", "-journal"] {
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
      }
    }
    let saved = ConnectionConfig(
      databaseType: .sqlite, host: "", port: 0, database: url.path, username: "",
      protectionLevel: .none, safeMode: .silent, protectedMode: true)
    let target = try await DatabaseConnectionManager.makeCopyTargetManager(
      config: saved, password: { _ in nil },
      makeManager: { DatabaseConnectionManager(lockSource: LockRegistry()) })
    #expect(target.config.protectedMode == false)
    #expect(target.policy.protectedMode == false)
    #expect(target.policy.protectionLevel == .none)
    let rows = try ImportSQLBuilder.insertStatements(
      schema: nil, table: "copied", columns: ["v"], rows: [["a"], ["b"]], dialect: .sqlite)
    let delivered = OSAllocatedUnfairLock(initialState: false)
    let epoch = await target.manager.connectionEpoch
    let inserted = try await target.manager.executeGatedBatch(
      streamed: StreamedBatch(
        relation: try SQLDialect.sqlite.qualified(schema: nil, name: "copied"),
        nextChunk: {
          delivered.withLock { sent in
            defer { sent = true }
            return sent ? nil : rows
          }
        }),
      policy: target.policy, connectionEpoch: epoch,
      prelude: [BoundStatement(sql: "CREATE TABLE copied (v TEXT)", values: [], expectedRows: nil)]
    )
    #expect(inserted == 2)
    let names = try await target.manager.copyTargetNames()
    #expect(names.schema == "main")
    #expect(names.existingNames.contains("copied"))
    await target.manager.disconnect()

    let reader = DatabaseConnectionManager(lockSource: LockRegistry())
    try await reader.connect(config: saved)
    let result = try await reader.executeInternal("SELECT count(*) FROM copied")
    guard case .int(let count) = result.rows.first?.first else {
      Issue.record("Expected a count")
      return
    }
    #expect(count == 2)
    await reader.disconnect()
  }

  private static func postgres(level: ConnectionProtectionLevel) -> ConnectionConfig {
    ConnectionConfig(
      databaseType: .postgresql, host: "fake", port: 5432, database: "db", username: "u",
      sslMode: .disable, protectionLevel: level, safeMode: .silent, protectedMode: true)
  }
}
