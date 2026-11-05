// PostgresViewEditTargetTests.swift
// A PostgreSQL view is an edit candidate only when the catalog proves every v1 rule: the UPDATE
// and DELETE bits of pg_relation_is_updatable, no INSTEAD OF trigger, no rule besides _RETURN,
// exactly one base relation that is a table, and a base primary key. The bits alone let a
// trigger or rule view through, so those are refused on their own. Attnum lists come as the
// server prints an `array_agg`: `{1,2}`, 1-based.

import Foundation
import Testing

@testable import Dblore

@Suite("PostgreSQL view edit candidate")
struct PostgresViewEditTargetTests {
  private static let viewOID = 16_500
  private static let baseOID = 16_400

  /// The view-level facts each catalog row repeats
  struct Facts: Sendable, CustomTestStringConvertible {
    var label = "simple view"
    var bits = 28
    var noInsteadTrigger = true
    var noOtherRule = true
    var baseCount = 1
    var baseKind: String? = "r"
    var baseHasSubclass = false
    var basePrimaryKey: String? = "{1}"
    var generatedBaseColumns: String? = nil

    var testDescription: String { label }
  }

  /// One `viewEditCandidate` row per view column: v1(id, a, a_plus_one) over t(id pk, a)
  private func rows(_ facts: Facts) -> [[CellValue]] {
    let base = facts.baseCount == 1
    return [(1, "id", true), (2, "a", true), (3, "a_plus_one", false)].map { column in
      [
        .int(Self.viewOID), .string("public.v1"), .string("public"), .string("v1"),
        .int(facts.bits), .bool(facts.noInsteadTrigger), .bool(facts.noOtherRule),
        .int(facts.baseCount), base ? .int(Self.baseOID) : .null,
        facts.baseKind.map(CellValue.string) ?? .null,
        base ? .bool(facts.baseHasSubclass) : .null,
        facts.basePrimaryKey.map(CellValue.string) ?? .null,
        .int(column.0), .string(column.1), .bool(column.2), .string("771"),
        facts.generatedBaseColumns.map(CellValue.string) ?? .null,
      ]
    }
  }

  private func candidate(_ facts: Facts) async throws -> (ViewEditCandidate?, [String]) {
    let session = FakeDatabaseSession(
      capabilities: .contract(), columns: [], rows: rows(facts), slowQueries: false)
    let candidate = try await PostgresSchemaIntrospector().viewEditCandidate(
      named: "v1", in: session)
    return (candidate, session.statements)
  }

  @Test("A simple view gives a candidate with its columns, the base OID and the key attnums")
  func simpleViewIsCandidate() async throws {
    let (found, statements) = try await candidate(Facts())
    let candidate = try #require(found)
    #expect(candidate.viewOID == UInt32(Self.viewOID))
    #expect(candidate.qualifiedName == "public.v1")
    #expect(candidate.columns == [1: "id", 2: "a", 3: "a_plus_one"])
    #expect(candidate.updatableColumnNames == ["id", "a"])
    #expect(candidate.baseOID == UInt32(Self.baseOID))
    #expect(candidate.basePrimaryKey == [1])
    #expect(candidate.generatedBaseColumns.isEmpty)
    #expect(candidate.definitionVersion == "771")
    // One catalog read, bound by name, checking the bits, triggers and rules
    #expect(statements.count == 1)
    let sql = try #require(statements.first)
    #expect(sql.contains("pg_catalog.pg_relation_is_updatable("))
    #expect(sql.contains("(g.tgtype OPERATOR(pg_catalog.&) 64) OPERATOR(pg_catalog.<>) 0"))
    #expect(sql.contains(#"w.ev_type OPERATOR(pg_catalog.<>) '1'::pg_catalog."char""#))
    // The key is re-aggregated in indkey order: `indkey::int2[]` text keeps lower bound 0
    #expect(sql.contains("pg_catalog.array_agg(k.att ORDER BY k.ord)"))
    #expect(!sql.contains("int2[]::pg_catalog.text"))
  }

  @Test("A composite key keeps its key order, and a generated base column is read-only")
  func compositeKeyAndGeneratedColumn() async throws {
    // v1(id, a, a_plus_one) over t: view id is base 1, view a is base 2
    let base = TableRef.postgresql(oid: UInt32(Self.baseOID))
    let origins = [
      ColumnOrigin(tableID: base, columnOrdinal: 1), ColumnOrigin(tableID: base, columnOrdinal: 2),
      nil,
    ]
    let composite = try #require(try await candidate(Facts(basePrimaryKey: "{2,1}")).0)
    #expect(composite.basePrimaryKey == [2, 1])
    let keyed = try ViewBaseMap.make(composite, origins: origins)
    #expect(keyed.primaryKeyColumns == ["a", "id"])
    // t.a GENERATED ALWAYS AS (...) STORED: the view column over it is never written
    let generated = try #require(try await candidate(Facts(generatedBaseColumns: "{2}")).0)
    #expect(generated.generatedBaseColumns == [2])
    let map = try ViewBaseMap.make(generated, origins: origins)
    let table = try #require(EditTable.view(generated, map: map, connectionEpoch: 1))
    #expect(table.generatedColumns == ["a", "a_plus_one"])
  }

  @Test(
    "A view the v1 rule does not accept is refused",
    arguments: [
      Facts(label: "INSERT and DELETE, no UPDATE (24)", bits: 24),
      Facts(label: "UPDATE and INSERT, no DELETE (12)", bits: 12),
      Facts(label: "bits 28 with an INSTEAD OF trigger", noInsteadTrigger: false),
      Facts(label: "bits 28 with a DO INSTEAD rule", noOtherRule: false),
      Facts(label: "a join", baseCount: 2, baseKind: nil, basePrimaryKey: nil),
      Facts(label: "a view on a view", baseKind: "v", basePrimaryKey: nil),
      Facts(label: "a view over a keyless table", basePrimaryKey: nil),
      // indkey::int2[] text as the server sends it (lower bound 0): never a partial key
      Facts(label: "a one-column key with bounds", basePrimaryKey: "[0:0]={1}"),
      Facts(label: "a two-column key with bounds", basePrimaryKey: "[0:1]={1,2}"),
      Facts(label: "a key that is not an attnum list", basePrimaryKey: "{1,x}"),
      Facts(label: "generated columns with bounds", generatedBaseColumns: "[0:0]={2}"),
    ])
  func refusedViews(_ facts: Facts) async throws {
    let (candidate, _) = try await candidate(facts)
    #expect(candidate == nil)
  }
}
