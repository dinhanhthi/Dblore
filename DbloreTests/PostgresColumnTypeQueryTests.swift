// PostgresColumnTypeQueryTests.swift
// Result column types (length, precision, scale) are read for each column's own table: the
// catalog statement binds the table OID and attribute numbers from the row description and
// never carries a result table or column name. A column with no table origin keeps its type.

import Foundation
import Testing

@testable import Dblore

@Suite("PostgreSQL result column types")
struct PostgresColumnTypeQueryTests {
  private let introspector = PostgresSchemaIntrospector()

  @Test("The catalog statement binds the table OID and attnums, never result names")
  func bindsOriginNotNames() async throws {
    let hostile = "v'); DROP TABLE accounts; --"
    // information_schema row for attnum 3: numeric(12,4)
    let session = FakeDatabaseSession(
      capabilities: .contract(), columns: [],
      rows: [
        [
          .int(3), .string("numeric"), .null, .int(12), .int(4), .null, .null,
          .string("numeric"),
        ]
      ],
      slowQueries: false)
    let columns = [
      ColumnInfo(name: hostile, type: "NUMERIC", tableOID: 16_400, attributeNumber: 3),
      ColumnInfo(name: "row_key", type: "INT4", tableOID: 16_400, attributeNumber: 1),
      // An expression (table OID 0) and a column with no origin, named like a table column
      ColumnInfo(name: hostile, type: "NUMERIC", tableOID: 0, attributeNumber: 0),
      ColumnInfo(name: hostile, type: "NUMERIC", origin: nil as ColumnOrigin?),
    ]

    let enriched = try await introspector.enrichedColumns(
      columns, query: "SELECT * FROM other_schema.ledger", in: session)

    #expect(enriched.map(\.type) == ["NUMERIC(12,4)", "INT4", "NUMERIC", "NUMERIC"])
    #expect(enriched.map(\.origin) == columns.map(\.origin))
    #expect(session.queries.count == 1)
    let sql = try #require(session.queries.first)
    #expect(sql.contains("$1::oid"))
    #expect(sql.contains("$2"))
    for name in [hostile, "row_key", "other_schema", "ledger", "'"] {
      #expect(!sql.contains(name), "statement carries \(name)")
    }
    #expect(session.statementBinds == [[.text("16400"), .text("{1,3}")]])
  }

  // MARK: - Live (CI only)

  @Test(
    "A result read from another schema gets that schema's column types",
    .requiresPostgres, .timeLimit(.minutes(1)))
  @MainActor
  func otherSchemaTypes() async throws {
    let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "_").lowercased()
    let first = "qa_coltype_a_\(suffix)"
    let other = "qa_coltype_b_\(suffix)"
    let manager = DatabaseConnectionManager()
    try await manager.connect(
      config: ConnectionConfig(
        host: TestDatabase.host, port: TestDatabase.port, database: TestDatabase.database,
        username: TestDatabase.username, password: TestDatabase.password, sslMode: .disable,
        timeoutSeconds: 30))
    func dropSchemas() async {
      _ = try? await manager.executeInternal("DROP SCHEMA IF EXISTS \(first) CASCADE")
      _ = try? await manager.executeInternal("DROP SCHEMA IF EXISTS \(other) CASCADE")
    }
    do {
      _ = try await manager.executeInternal("CREATE SCHEMA \(first)")
      _ = try await manager.executeInternal("CREATE SCHEMA \(other)")
      _ = try await manager.executeInternal("CREATE TABLE \(first).t (v NUMERIC(5,2))")
      _ = try await manager.executeInternal("CREATE TABLE \(other).t (v NUMERIC(12,4))")

      let result = try await manager.executeInternal("SELECT v FROM \(other).t")

      #expect(result.columns.map(\.type) == ["NUMERIC(12,4)"])
    } catch {
      await dropSchemas()
      await manager.disconnect()
      throw error
    }
    await dropSchemas()
    await manager.disconnect()
  }
}
