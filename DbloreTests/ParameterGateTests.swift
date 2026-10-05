// ParameterGateTests.swift
// Named parameters are rewritten and bound only when the caller passes a dictionary.
// nil leaves the text unchanged. A refusal sends nothing.

import Foundation
import Testing

@testable import Dblore

@Suite("ParameterGateTests")
struct ParameterGateTests {
  private let open = ProtectionPolicy(protectionLevel: .none, protectedMode: false)
  private let readOnly = ProtectionPolicy(protectionLevel: .readOnly)

  private func connect(
    databaseType: DatabaseType = .postgresql
  ) async throws -> (DatabaseConnectionManager, FakeDatabaseSessionFactory) {
    let factory = FakeDatabaseSessionFactory(capabilities: .contract())
    let manager = DatabaseConnectionManager(sessionFactory: factory)
    try await manager.connect(
      config: ConnectionConfig(
        databaseType: databaseType, host: "fake", port: 1, database: "db", username: "u",
        password: "p", sslMode: .disable, protectionLevel: .none, safeMode: .silent,
        protectedMode: false))
    return (manager, factory)
  }

  @Test("parameters nil sends the text unchanged and records empty binds")
  func nilParametersLeaveTextUnchanged() async throws {
    let (manager, factory) = try await connect()
    let plain = "SELECT id FROM items"
    let named = "SELECT id FROM items WHERE id = :id"

    _ = try await manager.execute(userSQL: plain, policy: open)
    _ = try await manager.execute(userSQL: named, parameters: nil, policy: open)

    let session = try #require(factory.sessions.first)
    #expect(session.statements == [plain, named])
    #expect(session.statementBinds == [[], []])
    #expect(!named.contains("$1"))
    #expect(session.statements[1] == named)
  }

  @Test("A PostgreSQL :name is sent as $1 and queryText stays the original")
  func postgresqlBindsNamedParameter() async throws {
    let (manager, factory) = try await connect()
    let sql = "SELECT id FROM items WHERE id = :id"

    let detailed = try await manager.executeDetailed(
      userSQL: sql, parameters: ["id": .text("7")], policy: open)

    let session = try #require(factory.sessions.first)
    #expect(session.statements == ["SELECT id FROM items WHERE id = $1"])
    #expect(session.statementBinds == [[.text("7")]])
    #expect(detailed.results.map(\.queryText) == [sql])
  }

  @Test("A repeated name reuses $1 and one bind")
  func repeatedNameReusesOneBind() async throws {
    let (manager, factory) = try await connect()
    let sql = "SELECT 1 WHERE :x IS NULL OR col = :x"

    _ = try await manager.execute(userSQL: sql, parameters: ["x": .null], policy: open)

    let session = try #require(factory.sessions.first)
    #expect(session.statements == ["SELECT 1 WHERE $1 IS NULL OR col = $1"])
    #expect(session.statementBinds == [[.null]])
  }

  @Test("Each statement restarts at $1 and queryText stays original")
  func twoStatementsRestartPlaceholders() async throws {
    let (manager, factory) = try await connect()
    let first = "SELECT id FROM items WHERE id = :id"
    let second = "SELECT name FROM items WHERE name = :name"
    let sql = "\(first); \(second)"

    let detailed = try await manager.executeDetailed(
      userSQL: sql, parameters: ["id": .text("7"), "name": .text("ada")], policy: open)

    let session = try #require(factory.sessions.first)
    #expect(
      session.statements == [
        "SELECT id FROM items WHERE id = $1",
        "SELECT name FROM items WHERE name = $1",
      ])
    #expect(session.statementBinds == [[.text("7")], [.text("ada")]])
    #expect(detailed.results.map(\.queryText) == [first, second])
  }

  @Test("A missing name on an allowed SELECT sends nothing")
  func missingParameterSendsNothing() async throws {
    let (manager, factory) = try await connect()

    do {
      _ = try await manager.execute(
        userSQL: "SELECT id FROM items WHERE id = :id", parameters: [:], policy: open)
      Issue.record("Expected missingParameters")
    } catch let error as DatabaseError {
      guard case .missingParameters(let names) = error else {
        Issue.record("Expected missingParameters, got \(error)")
        return
      }
      #expect(names == ["id"])
      let message = error.localizedDescription
      #expect(message.contains("id"))
      #expect(message.contains("Nothing was executed"))
    }

    let session = try #require(factory.sessions.first)
    #expect(session.statements.isEmpty)
  }

  @Test("Named and positional placeholders in one script send nothing")
  func mixedPlaceholdersSendNothing() async throws {
    let (manager, factory) = try await connect()
    let sql = "SELECT id FROM items WHERE id = :id; SELECT :a, $1"

    do {
      _ = try await manager.execute(
        userSQL: sql, parameters: ["id": .text("7"), "a": .text("x")], policy: open)
      Issue.record("Expected mixedPlaceholders")
    } catch let error as DatabaseError {
      guard case .mixedPlaceholders = error else {
        Issue.record("Expected mixedPlaceholders, got \(error)")
        return
      }
      #expect(error.localizedDescription.contains("Nothing was executed"))
    }

    let session = try #require(factory.sessions.first)
    #expect(session.statements.isEmpty)
  }

  @Test("Casts, assignment, and slices are not parameters")
  func castsAssignmentAndSlicesStayUnchanged() async throws {
    let (manager, factory) = try await connect()
    let sql = "SELECT a::int, arr[1:2], x := 1"

    _ = try await manager.execute(userSQL: sql, parameters: [:], policy: open)

    let session = try #require(factory.sessions.first)
    #expect(session.statements == [sql])
    #expect(session.statementBinds == [[]])
  }

  @Test("Read-only blocks a parameterized DELETE before anything is sent")
  func readOnlyBlocksParameterizedDelete() async throws {
    let (manager, factory) = try await connect()
    let sql = "DELETE FROM items WHERE id = :id"

    do {
      _ = try await manager.execute(
        userSQL: sql, parameters: ["id": .text("7")], policy: readOnly)
      Issue.record("Expected blockedByProtection")
    } catch DatabaseError.blockedByProtection {
      // expected
    } catch {
      Issue.record("Unexpected error: \(error)")
    }

    do {
      _ = try await manager.execute(userSQL: sql, parameters: [:], policy: readOnly)
      Issue.record("Expected blockedByProtection when the value is missing")
    } catch DatabaseError.blockedByProtection {
      // expected
    } catch DatabaseError.missingParameters {
      Issue.record("Policy must run before the missing-parameter check")
    } catch {
      Issue.record("Unexpected error: \(error)")
    }

    let session = try #require(factory.sessions.first)
    #expect(session.statements.isEmpty)
  }

  @Test("Protected mode sends rewritten SQL and previews the :name text")
  func protectedModePreviewKeepsNamedSQL() async throws {
    let (manager, factory) = try await connect()
    let sql = "UPDATE items SET name = :name"
    let protected = ProtectionPolicy(protectionLevel: .none, protectedMode: true)

    _ = try await manager.execute(
      userSQL: sql, parameters: ["name": .text("ada")], policy: protected)

    let session = try #require(factory.sessions.first)
    #expect(session.statements.contains("UPDATE items SET name = $1"))
    #expect(session.statementBinds.contains([.text("ada")]))
    let pending = await manager.transactionSnapshot().pending
    #expect(pending.count == 1)
    #expect(pending.first?.sqlPreview.contains(":name") == true)
    #expect(pending.first?.sqlPreview.contains("$1") == false)
  }

  @Test("SQLite sends ?n for :name, including LIMIT")
  func sqliteQuestionPlaceholders() async throws {
    let (manager, factory) = try await connect(databaseType: .sqlite)

    _ = try await manager.execute(
      userSQL: "SELECT id FROM items WHERE id = :id", parameters: ["id": .text("7")],
      policy: open)
    _ = try await manager.execute(
      userSQL: "SELECT id FROM items LIMIT :n", parameters: ["n": .text("2")], policy: open)

    let session = try #require(factory.sessions.first)
    #expect(
      session.statements == [
        "SELECT id FROM items WHERE id = ?1",
        "SELECT id FROM items LIMIT ?1",
      ])
    #expect(session.statementBinds == [[.text("7")], [.text("2")]])
  }
}
