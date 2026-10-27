// ColumnValueGeneratorTests.swift
// Generate Rows values: one seed gives the same rows, unique columns never repeat, and the NULL
// ratio, length, precision and integer width stay inside the column.

import Foundation
import Testing

@testable import Dblore

@Suite("Column value generator")
struct ColumnValueGeneratorTests {
  private func column(
    _ name: String, _ dataType: String, nullable: Bool = false, columnType: String? = nil
  ) -> TableStructure.Column {
    TableStructure.Column(
      ordinal: 1, name: name, dataType: dataType, isNullable: nullable, columnType: columnType)
  }

  private func generator(
    _ column: TableStructure.Column, unique: Bool = false, nullRatio: Double = 0,
    currentMax: Int? = nil
  ) throws -> ColumnValueGenerator {
    let kind = try #require(ColumnValueGenerator.defaultKind(for: column))
    return ColumnValueGenerator(
      column: column, kind: kind, isUnique: unique, nullRatio: nullRatio, currentMax: currentMax)
  }

  /// `count` rows, each column's value drawn in order from one seeded source
  private func rows(
    _ generators: [ColumnValueGenerator], count: Int, seed: UInt64
  ) throws -> [[String?]] {
    var generators = generators
    var random = Dblore.SeededGenerator(seed: seed)
    var rows: [[String?]] = []
    for _ in 0..<count {
      var row: [String?] = []
      for index in generators.indices {
        row.append(try generators[index].next(using: &random))
      }
      rows.append(row)
    }
    return rows
  }

  /// Column `index` of `rows`
  private func values(_ rows: [[String?]], _ index: Int) -> [String?] {
    rows.map { $0[index] }
  }

  @Test("The same seed gives the same rows; another seed gives other rows")
  func sameSeedSameRows() throws {
    let generators = [
      try generator(column("id", "integer"), unique: true, currentMax: 10),
      try generator(column("full_name", "character varying(40)")),
      try generator(column("email", "character varying(255)"), unique: true),
      try generator(column("price", "numeric(8,2)", nullable: true), nullRatio: 0.2),
      try generator(column("created_at", "timestamp without time zone")),
      try generator(column("token", "uuid")),
      ColumnValueGenerator(column: column("event_id", "uuid"), kind: .uuidV7, isUnique: false),
      try generator(column("active", "boolean")),
      try generator(column("status", "enum", columnType: "enum('new','paid','sent')")),
      try generator(column("payload", "jsonb")),
      try generator(column("phone", "text")),
      try generator(column("website", "text")),
      try generator(column("street_address", "text")),
      try generator(column("born_on", "date")),
    ]

    let first = try rows(generators, count: 200, seed: 7)

    #expect(try rows(generators, count: 200, seed: 7) == first)
    #expect(try rows(generators, count: 200, seed: 8) != first)
    #expect(first[0][0] == "11")
  }

  @Test("Unique columns never repeat over 100,000 rows; integer keys start after the MAX")
  func uniqueColumnsNeverRepeat() throws {
    let generators = [
      try generator(column("id", "bigint"), unique: true, currentMax: 41),
      try generator(column("email", "character varying(255)"), unique: true),
      // Six characters: the counter outgrows "-<count>" and continues as bare digits
      try generator(column("code", "character varying(6)"), unique: true),
      try generator(column("day", "date"), unique: true),
    ]

    let generated = try rows(generators, count: 100_000, seed: 1)

    for index in generators.indices {
      let column = values(generated, index).compactMap { $0 }
      #expect(column.count == 100_000)
      #expect(Set(column).count == 100_000)
    }
    #expect(generated[0][0] == "42")
    #expect(values(generated, 2).allSatisfy { ($0?.count ?? 0) <= 6 })
  }

  @Test("NULLs follow the ratio on nullable columns and never reach NOT NULL or unique ones")
  func nullRatio() throws {
    let generators = [
      try generator(column("note", "text", nullable: true), nullRatio: 0.25),
      try generator(column("title", "text"), nullRatio: 0.5),
      try generator(column("code", "text", nullable: true), unique: true, nullRatio: 1),
      try generator(column("memo", "text", nullable: true), nullRatio: 1),
    ]

    let generated = try rows(generators, count: 20_000, seed: 3)
    let share = Double(values(generated, 0).filter { $0 == nil }.count) / 20_000

    #expect((0.22...0.28).contains(share))
    #expect(values(generated, 1).allSatisfy { $0 != nil })
    #expect(values(generated, 2).allSatisfy { $0 != nil })
    #expect(values(generated, 3).allSatisfy { $0 == nil })
  }

  @Test("Text fits its length; numbers fit their precision and integer width")
  func boundsHonored() throws {
    let shortText = ["full_name", "email", "website", "note"].flatMap { name in
      [false, true].map { unique in (column(name, "varchar(5)"), unique) }
    }
    let generators =
      try shortText.map { try generator($0.0, unique: $0.1) } + [
        try generator(column("price", "numeric(5,2)")),
        try generator(column("small", "smallint")),
        try generator(column("level", "tinyint", columnType: "tinyint unsigned")),
        try generator(column("status", "enum", columnType: "enum('new','it''s')")),
      ]

    let generated = try rows(generators, count: 5_000, seed: 11)

    for index in shortText.indices {
      #expect(values(generated, index).allSatisfy { ($0?.count ?? 0) <= 5 })
    }
    for price in values(generated, shortText.count).compactMap({ $0 }) {
      let parts = price.split(separator: ".", omittingEmptySubsequences: false)
      #expect(parts.count <= 2 && parts[0].count <= 3 && (parts.count == 1 || parts[1].count <= 2))
      #expect(parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) })
    }
    #expect(
      values(generated, shortText.count + 1).allSatisfy {
        Int($0 ?? "").map { Int(Int16.min)...Int(Int16.max) ~= $0 } == true
      })
    #expect(
      values(generated, shortText.count + 2).allSatisfy {
        Int($0 ?? "").map { 0...255 ~= $0 } == true
      })
    #expect(Set(values(generated, shortText.count + 3).compactMap { $0 }) == ["new", "it's"])
  }

  @Test("A declared length below 1 counts as no length")
  func nonPositiveLength() throws {
    let negative = try [false, true].map { unique in
      try generator(column("note", "varchar(-5)"), unique: unique)
    }
    let generated = try rows(negative, count: 20, seed: 3)

    #expect(generated.count == 20)
    #expect(generated.allSatisfy { $0.count == 2 && $0.allSatisfy { !($0 ?? "").isEmpty } })
  }

  @Test("A unique integer key stops at its type's upper bound")
  func uniqueIntegerExhausts() throws {
    var level = try generator(
      column("level", "tinyint", columnType: "tinyint"), unique: true, currentMax: 126)
    var random = Dblore.SeededGenerator(seed: 5)

    #expect(try level.next(using: &random) == "127")
    #expect(throws: ColumnValueGenerator.Error.uniqueValuesExhausted(column: "level")) {
      try level.next(using: &random)
    }
  }

  @Test("The generator follows the column's type, then its name")
  func defaultKinds() {
    let cases: [(TableStructure.Column, ColumnValueGenerator.Kind?)] = [
      (column("email", "character varying(255)"), .email),
      (column("firstName", "text"), .firstName),
      (column("last_name", "varchar(50)"), .lastName),
      (column("phone_number", "text"), .phone),
      (column("homepage_url", "text"), .url),
      (column("street_address", "text"), .address),
      (column("city", "text"), .city),
      (column("name", "text"), .fullName),
      (column("notes", "text"), .text),
      (column("guid", "char(36)"), .uuidV4),
      (column("ref", "uuid"), .uuidV4),
      (column("id", "integer"), .integer),
      (column("flag", "tinyint", columnType: "tinyint(1)"), .boolean),
      (column("is_active", "boolean"), .boolean),
      (column("price", "numeric(10,2)"), .decimal),
      (column("ratio", "double precision"), .decimal),
      (column("created", "timestamp with time zone"), .timestamp),
      (column("opens", "time without time zone"), .time),
      (column("born", "date"), .date),
      (column("doc", "jsonb"), .json),
      (column("status", "enum", columnType: "enum('a','b')"), .enumLabel),
      (column("tags", "text[]"), nil),
      (column("addr", "inet"), nil),
      (column("span", "interval"), nil),
      (column("ids", "int4range"), nil),
    ]

    for (column, kind) in cases {
      #expect(ColumnValueGenerator.defaultKind(for: column) == kind, "\(column.name)")
    }
  }
}
