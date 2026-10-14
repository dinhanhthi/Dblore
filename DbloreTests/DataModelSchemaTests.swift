// DataModelSchemaTests.swift
// Unit tests for Database Schema data models (DatabaseTable, DatabaseView, DatabaseFunction, etc.)

import Foundation
import Testing

@testable import Dblore

@Suite("Data Model - Database Schema Tests")
@MainActor
struct DataModelSchemaTests {

  // MARK: - DatabaseTable Tests

  // MARK: - DatabaseColumn Type Icon Tests

  // MARK: - DatabaseView Tests

  // MARK: - DatabaseFunction Tests

  // MARK: - DatabaseProcedure Tests

  // MARK: - DatabaseUser Tests

  // MARK: - DatabaseRole Tests

  // MARK: - DatabaseFunction oid

  // MARK: - DatabaseTrigger Tests

  @Test("DatabaseTrigger id is keyed by oid when present")
  func databaseTriggerIdUsesOid() {
    let a = DatabaseTrigger(
      schema: "public", table: "users", name: "audit", timing: .before, events: [.delete],
      enabled: true, oid: 1)
    let b = DatabaseTrigger(
      schema: "public", table: "orders", name: "audit", timing: .before, events: [.delete],
      enabled: true, oid: 2)

    #expect(a.id != b.id)
  }

  @Test("DatabaseTrigger without oid is keyed by schema, table and name")
  func databaseTriggerIdWithoutOid() {
    let a = DatabaseTrigger(
      schema: "main", table: "users", name: "audit", timing: .insteadOf, events: [.insert],
      enabled: true)
    let renamed = DatabaseTrigger(
      schema: "main", table: "users", name: "audit2", timing: .insteadOf, events: [.insert],
      enabled: true)
    let disabled = DatabaseTrigger(
      schema: "main", table: "users", name: "audit", timing: .insteadOf, events: [.insert],
      enabled: false)

    #expect(a.oid == nil)
    #expect(a.id != renamed.id)
    #expect(a.id == disabled.id)
  }
}

/// Implements only the required reads so the protocol defaults are exercised.
private struct MinimalIntrospector: SchemaIntrospector {
  func tables(in session: any DatabaseSession) async throws -> [DatabaseTable] { [] }
  func views(in session: any DatabaseSession) async throws -> [DatabaseView] { [] }
  func foreignKeys(in session: any DatabaseSession) async throws -> [ForeignKey] { [] }
  func allColumns(in session: any DatabaseSession) async throws -> [String: [DatabaseColumn]] {
    [:]
  }
  func editTable(named name: String, in session: any DatabaseSession) async throws -> EditTable? {
    nil
  }
  func enrichColumnTypes(
    _ columns: [ColumnInfo], query: String, in session: any DatabaseSession
  ) async -> [ColumnInfo] { columns }
  func rowCount(
    schema: String, table: String, in session: any DatabaseSession
  ) async throws
    -> Int
  { 0 }
  func primaryKeyColumns(
    of tableName: String, in session: any DatabaseSession
  ) async throws
    -> [String]
  { [] }
  func tableStructure(
    schema: String, table: String, in session: any DatabaseSession
  ) async throws -> TableStructure { throw DatabaseError.notConnected }
}
